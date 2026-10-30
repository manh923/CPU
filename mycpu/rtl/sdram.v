// SDRAM の制御回路（Tang Nano 20K の GW2AR-18 に入っている 64Mbit、2M × 32bit：4 バンク × 2048 行 × 256 列）
//   CPU 側：req を 1 クロック立てると、終わったときに ack を 1 クロック立てる（読み出しなら rdata に値）
//   burst を 1 にした読み出しは、waddr（16 語の境目）から 16 語を続けて読む（キャッシュのライン読み込み）。
//   1 語届くたびに bvalid が 1 クロック立ち（rdata に値）、最後の語で ack も立つ
//   burst を 1 にした書き込み（wstrb は 1111）は、16 語を続けて書く（データキャッシュの書き戻し）。
//   bidx が「このクロックで書く語の番号」で、同じクロックの bwdata をその語として取り込む。書き終えたら ack
//   1 回ごとに行を開き（ACTIVE）、自動プリチャージ付きの READ / WRITE をする。バースト長 1、CAS レイテンシ 2
//   SDRAM のクロックは clk を反転したもの。SDRAM はこちらの出力が変わってから半周期後に読み取る
//   リフレッシュは 7.8µs ごと（64ms に 4096 回の倍の頻度）
// タイミングは SDRAM_HZ（このクロックの実際の周波数）から計算する。
// ※実機ではまだ動かしていない。tb/sdram_model.v（タイミング違反を調べるモデル）でだけ確かめてある
module mycpu_sdram #(
  parameter integer SDRAM_HZ = 27_000_000
) (
  input  wire        clk,
  input  wire        rst,
  // CPU 側
  input  wire        req,
  input  wire [20:0] waddr,        // 4 バイト単位の番地
  input  wire [3:0]  wstrb,        // 0 なら読み出し
  input  wire [31:0] wdata,
  input  wire        burst,
  input  wire [31:0] bwdata,       // バースト書き込みの語（bidx 番目）
  output wire [3:0]  bidx,
  output reg         ack,
  output reg         bvalid,
  output reg  [31:0] rdata,
  output reg         ready_init,   // 初期化が終わった
  // SDRAM 側
  output wire        sdram_clk,
  output wire        sdram_cke,
  output reg         sdram_cs_n,
  output reg         sdram_ras_n,
  output reg         sdram_cas_n,
  output reg         sdram_we_n,
  output reg  [10:0] sdram_a,
  output reg  [1:0]  sdram_ba,
  output reg  [3:0]  sdram_dqm,
  inout  wire [31:0] sdram_dq
);
  // ns → クロック数（切り上げ、最低 1）
  function integer ck(input integer ns);
    integer v;
    begin
      v = (ns * (SDRAM_HZ / 1000) + 999_999) / 1_000_000;
      ck = v < 1 ? 1 : v;
    end
  endfunction
  localparam integer T_INIT = SDRAM_HZ / 5000 + 1;   // 電源投入後 200µs
  localparam integer T_RP   = ck(20);
  localparam integer T_RCD  = ck(20);
  localparam integer T_RFC  = ck(70);
  localparam integer T_RAS  = ck(42);
  localparam integer T_WR   = ck(15) + 1;           // 書き込みの後、プリチャージが始まるまで（余裕を見て +1）
  localparam integer T_MRD  = 2;
  localparam integer CL     = 2;
  localparam integer T_REFI = SDRAM_HZ / 1_000_000 * 78 / 10;   // 7.8µs
  localparam [10:0]  MODE   = 11'b0000_010_0_000;                // バースト長 1、順番、CAS レイテンシ 2

  // 命令（CS RAS CAS WE）
  localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                   C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

  assign sdram_clk = ~clk;
  assign sdram_cke = 1'b1;

  reg [31:0] dq_out;
  reg        dq_oe;
  assign sdram_dq = dq_oe ? dq_out : 32'bz;

  localparam [3:0] S_INIT = 4'd0, S_PREALL = 4'd1, S_INITREF = 4'd2, S_MRS = 4'd3, S_IDLE = 4'd4,
                   S_RW = 4'd5, S_RDATA = 4'd6, S_WAIT = 4'd7, S_REF = 4'd8, S_BURST = 4'd9, S_BURSTW = 4'd10;
  reg [3:0]  state;
  reg [15:0] wait_n;           // 次の状態に進むまでのクロック数
  reg [3:0]  nref;             // 初期化のリフレッシュの回数
  reg [15:0] refi;             // リフレッシュの間隔を数える
  reg        ref_due;
  reg [20:0] r_addr;
  reg [3:0]  r_wstrb;
  reg [31:0] r_wdata;
  reg        pend;             // 受け付けたがまだ始めていない
  reg        r_burst;
  reg [3:0]  bcnt;             // バースト：次に READ する列（下位 4bit）
  reg        iss, iss_last, cap, cap_last;   // READ を出した → CL（2）クロック後に取り込む
  assign bidx = state == S_BURSTW ? bcnt : 4'd0;

  task cmd(input [3:0] c);
    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= c;
  endtask

  always @(posedge clk) begin
    if (rst) begin
      state <= S_INIT; wait_n <= T_INIT[15:0]; nref <= 4'd0; refi <= 16'd0; ref_due <= 1'b0;
      cmd(C_NOP); sdram_a <= 11'd0; sdram_ba <= 2'd0; sdram_dqm <= 4'hF;
      dq_oe <= 1'b0; dq_out <= 32'd0; ack <= 1'b0; rdata <= 32'd0; ready_init <= 1'b0; pend <= 1'b0;
      r_addr <= 21'd0; r_wstrb <= 4'd0; r_wdata <= 32'd0; r_burst <= 1'b0; bcnt <= 4'd0;
      iss <= 1'b0; iss_last <= 1'b0; cap <= 1'b0; cap_last <= 1'b0; bvalid <= 1'b0;
    end else begin
      cmd(C_NOP);
      dq_oe <= 1'b0;
      ack <= 1'b0;
      bvalid <= 1'b0;
      iss <= 1'b0; iss_last <= 1'b0;
      // バーストの読み出し：READ の 1 クロック後に cap、そのまた 1 クロック後（READ から CL = 2）に取り込む
      cap <= iss; cap_last <= iss_last;
      if (cap) begin rdata <= sdram_dq; bvalid <= 1'b1; if (cap_last) ack <= 1'b1; end
      if (req) begin pend <= 1'b1; r_addr <= waddr; r_wstrb <= wstrb; r_wdata <= wdata; r_burst <= burst; end
      if (refi == T_REFI - 1) begin refi <= 16'd0; ref_due <= 1'b1; end
      else refi <= refi + 16'd1;
      if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
      else case (state)
        S_INIT: begin                          // 200µs 待った：全バンクをプリチャージ
          cmd(C_PRE); sdram_a[10] <= 1'b1;
          state <= S_PREALL; wait_n <= T_RP - 1;
        end
        S_PREALL, S_INITREF: begin             // リフレッシュを 8 回
          if (nref == 4'd8) begin
            cmd(C_MRS); sdram_a <= MODE; sdram_ba <= 2'd0;
            state <= S_MRS; wait_n <= T_MRD - 1;
          end else begin
            cmd(C_REF); nref <= nref + 4'd1;
            state <= S_INITREF; wait_n <= T_RFC - 1;
          end
        end
        S_MRS: begin state <= S_IDLE; ready_init <= 1'b1; sdram_dqm <= 4'h0; refi <= 16'd0; ref_due <= 1'b0; end
        S_IDLE: begin
          if (ref_due) begin                   // リフレッシュを先に
            cmd(C_REF); ref_due <= 1'b0;
            state <= S_WAIT; wait_n <= T_RFC - 1;
          end else if (pend || req) begin      // 行を開く：行 = [20:10]、バンク = [9:8]、列 = [7:0]
            cmd(C_ACT);
            sdram_a <= req ? waddr[20:10] : r_addr[20:10];
            sdram_ba <= req ? waddr[9:8] : r_addr[9:8];
            state <= S_RW; wait_n <= T_RCD - 1;
          end
        end
        S_RW: begin                            // A10 = 1 で自動プリチャージ
          pend <= 1'b0;
          sdram_a <= {3'b100, r_addr[7:0]};
          if (r_wstrb != 4'd0 && r_burst) begin   // バースト書き込み：自動プリチャージなしで WRITE を 16 回
            cmd(C_WRITE);
            sdram_a <= {3'b000, r_addr[7:0]};
            dq_oe <= 1'b1; dq_out <= bwdata; sdram_dqm <= 4'h0;
            bcnt <= 4'd1;
            state <= S_BURSTW;
          end else if (r_wstrb != 4'd0) begin
            cmd(C_WRITE);
            dq_oe <= 1'b1; dq_out <= r_wdata; sdram_dqm <= ~r_wstrb;
            ack <= 1'b1;
            // 次の ACTIVE まで：書き込みの回復 ＋ プリチャージ（ACTIVE からは tRAS ＋ tRP 以上）
            state <= S_WAIT;
            wait_n <= (T_WR + T_RP > T_RAS + T_RP - T_RCD ? T_WR + T_RP : T_RAS + T_RP - T_RCD) - 1;
          end else if (r_burst) begin        // バースト：自動プリチャージなしで READ を 16 回
            cmd(C_READ);
            sdram_a <= {3'b000, r_addr[7:0]};
            iss <= 1'b1;
            bcnt <= 4'd1;
            state <= S_BURST;
          end else begin
            cmd(C_READ);
            state <= S_RDATA; wait_n <= CL - 1;
          end
        end
        S_BURST: begin
          if (bcnt != 4'd0) begin              // 最後（16 回目）だけ A10 = 1（自動プリチャージ）
            cmd(C_READ);
            sdram_a <= {bcnt == 4'd15 ? 3'b100 : 3'b000, r_addr[7:4], bcnt};
            iss <= 1'b1; iss_last <= bcnt == 4'd15;
            bcnt <= bcnt + 4'd1;
          end else begin                       // 出し終えた：最後の READ から 1 クロック後にプリチャージが始まる
            state <= S_WAIT;
            wait_n <= (T_RP > CL ? T_RP : CL) - 1;
          end
        end
        S_BURSTW: begin                        // 最後（16 回目）だけ A10 = 1（自動プリチャージ）
          cmd(C_WRITE);
          sdram_a <= {bcnt == 4'd15 ? 3'b100 : 3'b000, r_addr[7:4], bcnt};
          dq_oe <= 1'b1; dq_out <= bwdata;
          bcnt <= bcnt + 4'd1;
          if (bcnt == 4'd15) begin             // 書き込みの回復 ＋ プリチャージ
            ack <= 1'b1;
            state <= S_WAIT;
            wait_n <= T_WR + T_RP - 1;
          end
        end
        S_RDATA: begin                         // READ から CL クロック後に取り込む
          rdata <= sdram_dq;
          ack <= 1'b1;
          state <= S_WAIT;
          wait_n <= (T_RP > T_RAS - T_RCD - CL + T_RP ? T_RP : T_RAS - T_RCD - CL + T_RP) - 1;
        end
        S_WAIT: begin state <= S_IDLE; sdram_dqm <= 4'h0; end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
