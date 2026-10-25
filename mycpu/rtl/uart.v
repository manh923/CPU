// UART（8N1）。送信・受信とも 16 バイトの FIFO 付き。
// DIV = クロック周波数 / ボーレート（27MHz・115200bps なら 234）
module mycpu_uart #(
  parameter integer DIV = 234
) (
  input  wire       clk,
  input  wire       rst,
  // 送信：tx_we で 1 バイト積む（満杯なら捨てる）
  input  wire       tx_we,
  input  wire [7:0] tx_data,
  output wire       tx_ready,   // FIFO に空きがある
  output reg        txd,
  // 受信：rx_re で 1 バイト取り出す
  input  wire       rx_re,
  output wire [7:0] rx_data,
  output wire       rx_valid,   // FIFO にデータがある
  input  wire       rxd
);
  // ---- 送信 ----
  reg [7:0] tq [0:15];
  reg [4:0] tw, tr;   // 書き込み・読み出し位置（5bit 目で満杯と空を見分ける）
  assign tx_ready = (tw - tr) != 5'd16;
  reg [8:0]  tsh;     // 残りのデータ bit とストップ bit
  reg [3:0]  tbits;   // 残りの bit 期間（スタート bit から数えて 10）
  reg [15:0] tcnt;
  always @(posedge clk) begin
    if (rst) begin
      tw <= 5'd0; tr <= 5'd0; txd <= 1'b1; tbits <= 4'd0; tcnt <= 16'd0;
    end else begin
      if (tx_we && tx_ready) begin
        tq[tw[3:0]] <= tx_data;
        tw <= tw + 5'd1;
      end
      if (tbits == 4'd0) begin
        if (tw != tr) begin
          txd <= 1'b0;              // スタート bit
          tsh <= {1'b1, tq[tr[3:0]]};
          tr <= tr + 5'd1;
          tbits <= 4'd10;
          tcnt <= 16'd0;
        end
      end else if (tcnt == DIV - 1) begin
        tcnt <= 16'd0;
        tbits <= tbits - 4'd1;
        txd <= tbits > 4'd1 ? tsh[0] : 1'b1;
        tsh <= {1'b1, tsh[8:1]};
      end else tcnt <= tcnt + 16'd1;
    end
  end

  // ---- 受信 ----
  reg [7:0] rq [0:15];
  reg [4:0] rw, rr;
  assign rx_valid = rw != rr;
  assign rx_data = rq[rr[3:0]];
  reg [2:0]  rsync;
  reg [3:0]  rbits;
  reg [15:0] rcnt;
  reg [7:0]  rsh;
  wire rin = rsync[2];
  always @(posedge clk) begin
    if (rst) begin
      rw <= 5'd0; rr <= 5'd0; rsync <= 3'b111; rbits <= 4'd0; rcnt <= 16'd0;
    end else begin
      rsync <= {rsync[1:0], rxd};
      if (rx_re && rx_valid) rr <= rr + 5'd1;
      if (rbits == 4'd0) begin
        if (!rin) begin           // スタート bit の始まり → 半 bit 後に確かめる
          rbits <= 4'd10;
          rcnt <= DIV / 2;
        end
      end else if (rcnt == DIV - 1) begin
        rcnt <= 16'd0;
        rbits <= rbits - 4'd1;
        if (rbits == 4'd10) begin
          if (rin) rbits <= 4'd0;  // ノイズだった
        end else if (rbits == 4'd1) begin
          if (rin && (rw - rr) != 5'd16) begin   // ストップ bit が正しく、空きがあれば積む
            rq[rw[3:0]] <= rsh;
            rw <= rw + 5'd1;
          end
        end else rsh <= {rin, rsh[7:1]};
      end else rcnt <= rcnt + 16'd1;
    end
  end
endmodule
