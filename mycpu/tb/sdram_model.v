// SDRAM（2M × 32bit：4 バンク × 2048 行 × 256 列）のモデル。テストベンチ用。
//   バースト長 1 だけ。CAS レイテンシはモードレジスタのとおり（2 か 3）。
//   自動プリチャージなしの READ で行を開いたまま続けて読める（最後は自動プリチャージ付きの READ か PRECHARGE）
//   タイミングを調べて、違反があれば "sdram_model: エラー（英語の理由）" を出して errors を増やす：
//     電源投入後 200µs・プリチャージ・リフレッシュ 2 回以上の後にモード設定、モード設定の前のアクセス、
//     開いていない行への READ / WRITE、開いている行への ACTIVE、tRCD・tRAS・tRP・tRC・tRFC・tWR・tMRD、
//     リフレッシュの間隔（64ms に 4096 回 = 15.6µs）
//   時間は SDRAM_HZ（実機で動かすときの周波数）のクロック数で数える。シミュレーションの時間とは関係ない
`timescale 1ns / 1ps
module sdram_model #(
  parameter integer SDRAM_HZ = 27_000_000
) (
  input  wire        clk,
  input  wire        cke,
  input  wire        cs_n,
  input  wire        ras_n,
  input  wire        cas_n,
  input  wire        we_n,
  input  wire [1:0]  ba,
  input  wire [10:0] a,
  input  wire [3:0]  dqm,
  inout  wire [31:0] dq
);
  function integer ck(input integer ns);
    integer v;
    begin
      v = (ns * (SDRAM_HZ / 1000) + 999_999) / 1_000_000;
      ck = v < 1 ? 1 : v;
    end
  endfunction
  localparam integer T_INIT = SDRAM_HZ / 5000;           // 200µs
  localparam integer T_RCD = ck(18), T_RP = ck(18), T_RAS = ck(42), T_RC = ck(60), T_RFC = ck(60), T_WR = ck(14) < 2 ? 2 : ck(14);   // tWR は 2 クロック以上
  localparam integer T_REF = SDRAM_HZ / 64000;           // 15.625µs（これより長く空けたらエラー）

  reg [31:0] mem [0:2 * 1024 * 1024 - 1];
  integer i;
  initial for (i = 0; i < 2 * 1024 * 1024; i = i + 1) mem[i] = 32'h0;

  integer cyc = 0, errors = 0, nrefs = 0, last_ref = -1;
  integer cl = 0;                  // 0 = モード設定の前
  reg     pre_all = 1'b0;          // 初期化のプリチャージをした
  reg        open   [0:3];
  reg [10:0] row    [0:3];
  integer    t_act  [0:3];         // ACTIVE した時刻
  integer    t_pre  [0:3];         // プリチャージが始まる（始まった）時刻
  integer    t_wr   [0:3];         // 最後に WRITE した時刻（PRECHARGE までに tWR）
  integer    reads = 0, writes = 0;
  initial for (i = 0; i < 4; i = i + 1) begin open[i] = 1'b0; t_act[i] = -1000; t_pre[i] = -1000; t_wr[i] = -1000; end

  // 読み出しの出力（CAS レイテンシの分だけ遅らせる）
  reg [31:0] q [0:3];
  reg        qv [0:3];
  reg [31:0] dout;
  reg        doe = 1'b0;
  assign dq = doe ? dout : 32'bz;
  initial for (i = 0; i < 4; i = i + 1) qv[i] = 1'b0;

  task err(input [8*128-1:0] what);
    begin
      errors = errors + 1;
      if (errors <= 10) $display("sdram_model: エラー %0s（%0d クロック目、バンク %0d）", what, cyc, ba);
    end
  endtask

  wire [3:0] c = {cs_n, ras_n, cas_n, we_n};
  wire [20:0] waddr = {row[ba], ba, a[7:0]};
  integer b;
  always @(posedge clk) begin
    cyc = cyc + 1;
    // 出力：CL 番目のクロックの後に出し、次のクロックの後まで保つ
    #1;
    doe = qv[0];
    dout = q[0];
    for (b = 0; b < 3; b = b + 1) begin q[b] = q[b + 1]; qv[b] = qv[b + 1]; end
    qv[3] = 1'b0;
    if (!cke) err("CKE is 0");
    if (last_ref >= 0 && cyc - last_ref > T_REF) begin err("refresh interval too long"); last_ref = cyc; end
    if (c != 4'b0111 && c[3] == 1'b0) begin
      if (cyc < T_INIT) err("command before 200us");
      case (c)
        4'b0011: begin                                     // ACTIVE
          if (cl == 0) err("ACTIVE before mode set");
          if (open[ba]) err("ACTIVE on open bank");
          if (cyc - t_act[ba] < T_RC) err("tRC");
          if (cyc - t_pre[ba] < T_RP) err("tRP");
          if (last_ref >= 0 && cyc - last_ref < T_RFC) err("tRFC");
          open[ba] = 1'b1; row[ba] = a; t_act[ba] = cyc;
        end
        4'b0101, 4'b0100: begin                            // READ / WRITE
          if (!open[ba]) err("READ/WRITE on closed bank");
          if (cyc - t_act[ba] < T_RCD) err("tRCD");
          if (c == 4'b0101) begin
            reads = reads + 1;
            // DQM が 1 のバイトは出さない（読み出しの DQM は 2 クロック遅れて効く。BL1・CL2 なら READ のときの値）
            q[cl - 2] = mem[waddr]; qv[cl - 2] = 1'b1;
            for (b = 0; b < 4; b = b + 1) if (dqm[b]) q[cl - 2][8 * b +: 8] = 8'hzz;
            if (a[10]) begin open[ba] = 1'b0; t_pre[ba] = (cyc + 1 > t_act[ba] + T_RAS) ? cyc + 1 : t_act[ba] + T_RAS; end
          end else begin
            writes = writes + 1;
            t_wr[ba] = cyc;
            if (!dqm[0]) mem[waddr][7:0]   = dq[7:0];
            if (!dqm[1]) mem[waddr][15:8]  = dq[15:8];
            if (!dqm[2]) mem[waddr][23:16] = dq[23:16];
            if (!dqm[3]) mem[waddr][31:24] = dq[31:24];
            if (a[10]) begin open[ba] = 1'b0; t_pre[ba] = (cyc + T_WR > t_act[ba] + T_RAS) ? cyc + T_WR : t_act[ba] + T_RAS; end
          end
        end
        4'b0010: begin                                     // PRECHARGE
          for (b = 0; b < 4; b = b + 1) if (a[10] || b == ba) begin
            if (open[b] && cyc - t_act[b] < T_RAS) err("tRAS");
            if (open[b] && cyc - t_wr[b] < T_WR) err("tWR");
            if (open[b] || t_pre[b] < 0) t_pre[b] = cyc;
            open[b] = 1'b0;
          end
          if (a[10]) pre_all = 1'b1;
        end
        4'b0001: begin                                     // AUTO REFRESH
          for (b = 0; b < 4; b = b + 1) begin
            if (open[b]) err("REFRESH with open bank");
            if (cyc - t_pre[b] < T_RP) err("tRP (REFRESH)");
          end
          if (!pre_all) err("REFRESH before precharge");
          if (last_ref >= 0 && cyc - last_ref < T_RFC) err("tRFC");
          nrefs = nrefs + 1; last_ref = cyc;
        end
        4'b0000: begin                                     // MODE REGISTER SET
          if (nrefs < 2) err("mode set before 2 refreshes");
          if (a[2:0] != 3'b000) err("burst length is not 1");
          if (a[6:4] != 3'd2 && a[6:4] != 3'd3) err("CAS latency is not 2 or 3");
          if (last_ref >= 0 && cyc - last_ref < T_RFC) err("tRFC");
          cl = a[6:4];
        end
        default: err("unknown command");
      endcase
    end
  end
endmodule
