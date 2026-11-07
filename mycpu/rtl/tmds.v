// DVI の TMDS 符号化（8bit → 10bit、直流の偏りを抑える）。DVI 1.0 の手順どおり。
// 2 段に分けてある（74.25MHz に間に合わせるため）。出力は入力の 2 クロック後
//   1 段目：XOR か XNOR かを決め、9bit の中間の値 qm を作る
//   2 段目：qm の 1 の数と、それまでの偏りから、反転するかを決めて 10bit にする
module mycpu_tmds (
  input  wire       clk,
  input  wire       de,
  input  wire [7:0] d,
  input  wire [1:0] c,     // 表示期間外に送る制御信号（青チャンネルは {vs, hs}）
  output reg  [9:0] q
);
  function [3:0] ones(input [7:0] x);
    integer i;
    begin
      ones = 4'd0;
      for (i = 0; i < 8; i = i + 1) ones = ones + x[i];
    end
  endfunction

  // ---- 1 段目 ----
  // qm[i] は d[0]〜d[i] の XOR（XNOR のときは、i が奇数の bit だけ反転）。前の bit を待たずに各 bit を作る
  wire [3:0] n1 = ones(d);
  wire use_xnor = n1 > 4'd4 || (n1 == 4'd4 && !d[0]);
  wire [7:0] px;
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : stage
      assign px[i] = ^d[i:0];
    end
  endgenerate
  wire [8:0] qm = {!use_xnor, px ^ (use_xnor ? 8'b1010_1010 : 8'b0000_0000)};
  reg  [8:0] qm1;
  reg        de1;
  reg  [1:0] c1;
  always @(posedge clk) begin
    qm1 <= qm; de1 <= de; c1 <= c;
  end

  // ---- 2 段目 ----
  wire [3:0] q1 = ones(qm1[7:0]);
  wire signed [5:0] diff = $signed({1'b0, q1, 1'b0}) - 6'sd8;   // 1 の数 − 0 の数
  reg  signed [5:0] cnt;                                          // それまでの偏り
  wire signed [5:0] two_q8  = qm1[8] ? 6'sd2 : 6'sd0;
  wire signed [5:0] two_nq8 = qm1[8] ? 6'sd0 : 6'sd2;
  always @(posedge clk) begin
    if (!de1) begin
      cnt <= 6'sd0;
      case (c1)
        2'b00: q <= 10'b1101010100;
        2'b01: q <= 10'b0010101011;
        2'b10: q <= 10'b0101010100;
        default: q <= 10'b1010101011;
      endcase
    end else if (cnt == 0 || diff == 0) begin
      q <= {~qm1[8], qm1[8], qm1[8] ? qm1[7:0] : ~qm1[7:0]};
      cnt <= qm1[8] ? cnt + diff : cnt - diff;
    end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
      q <= {1'b1, qm1[8], ~qm1[7:0]};
      cnt <= cnt + two_q8 - diff;
    end else begin
      q <= {1'b0, qm1[8], qm1[7:0]};
      cnt <= cnt - two_nq8 + diff;
    end
  end
endmodule
