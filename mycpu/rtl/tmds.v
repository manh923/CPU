// DVI の TMDS 符号化（8bit → 10bit、直流の偏りを抑える）。DVI 1.0 の手順どおり。
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

  wire [3:0] n1 = ones(d);
  wire use_xnor = n1 > 4'd4 || (n1 == 4'd4 && !d[0]);
  wire [8:0] qm;
  assign qm[0] = d[0];
  genvar i;
  generate
    for (i = 1; i < 8; i = i + 1) begin : stage
      assign qm[i] = use_xnor ? ~(qm[i - 1] ^ d[i]) : (qm[i - 1] ^ d[i]);
    end
  endgenerate
  assign qm[8] = !use_xnor;

  wire [3:0] q1 = ones(qm[7:0]);
  wire signed [5:0] diff = $signed({1'b0, q1, 1'b0}) - 6'sd8;   // 1 の数 − 0 の数
  reg  signed [5:0] cnt;                                          // それまでの偏り
  wire signed [5:0] two_q8  = qm[8] ? 6'sd2 : 6'sd0;
  wire signed [5:0] two_nq8 = qm[8] ? 6'sd0 : 6'sd2;
  always @(posedge clk) begin
    if (!de) begin
      cnt <= 6'sd0;
      case (c)
        2'b00: q <= 10'b1101010100;
        2'b01: q <= 10'b0010101011;
        2'b10: q <= 10'b0101010100;
        default: q <= 10'b1010101011;
      endcase
    end else if (cnt == 0 || diff == 0) begin
      q <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
      cnt <= qm[8] ? cnt + diff : cnt - diff;
    end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
      q <= {1'b1, qm[8], ~qm[7:0]};
      cnt <= cnt + two_q8 - diff;
    end else begin
      q <= {1'b0, qm[8], qm[7:0]};
      cnt <= cnt - two_nq8 + diff;
    end
  end
endmodule
