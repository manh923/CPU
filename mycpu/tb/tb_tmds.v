// TMDS 符号器のテスト：でたらめな画素を符号化し、元に戻せるか・直流の偏りが小さいままかを確かめる
`timescale 1ns / 1ps
module tb_tmds;
  reg clk = 1'b0;
  always #1 clk = ~clk;
  reg        de = 1'b0;
  reg  [7:0] d = 8'd0;
  reg  [1:0] c = 2'd0;
  wire [9:0] q;
  mycpu_tmds enc (.clk(clk), .de(de), .d(d), .c(c), .q(q));

  function [7:0] decode(input [9:0] x);
    reg [7:0] t;
    integer i;
    begin
      t = x[9] ? ~x[7:0] : x[7:0];
      decode[0] = t[0];
      for (i = 1; i < 8; i = i + 1) decode[i] = x[8] ? t[i] ^ t[i - 1] : ~(t[i] ^ t[i - 1]);
    end
  endfunction

  function [3:0] ones10(input [9:0] x);
    integer i;
    begin
      ones10 = 4'd0;
      for (i = 0; i < 10; i = i + 1) ones10 = ones10 + x[i];
    end
  endfunction

  localparam [39:0] CTRL = {10'b1010101011, 10'b0101010100, 10'b0010101011, 10'b1101010100};
  integer n, errors, bal, worst;
  reg [7:0] pd, nd;
  reg       pde, nde;
  reg [1:0] pc, nc;
  initial begin
    errors = 0; bal = 0; worst = 0; nde = 1'b0; nd = 8'd0; nc = 2'd0;
    for (n = 0; n < 50000; n = n + 1) begin
      @(negedge clk);
      // 表示期間は長めに、たまに表示期間外（制御信号）を挟む
      de = ($random & 63) != 0;
      d = (n % 3 == 0) ? 8'hFF : (n % 7 == 0) ? 8'h00 : $random;
      c = $random;
      // 符号器の出力は入力の 2 クロック後：この後の posedge で出てくるのは 1 つ前に入れたもの
      pd = nd; pde = nde; pc = nc;
      nd = d; nde = de; nc = c;
      @(posedge clk); #0.5;
      if (n == 0) ;   // まだ何も出てこない
      else if (pde) begin
        if (decode(q) !== pd) begin
          errors = errors + 1;
          if (errors < 5) $display("NG: %02x → %b → %02x", pd, q, decode(q));
        end
        bal = bal + ones10(q) * 2 - 10;
        if (bal > worst) worst = bal;
        if (-bal > worst) worst = -bal;
      end else begin
        bal = 0;
        if (q !== CTRL[pc * 10 +: 10]) begin
          errors = errors + 1;
          $display("NG: 制御 %b → %b", pc, q);
        end
      end
    end
    // DVI の手順どおりなら、偏りはいつも小さい範囲に収まる
    if (worst > 20) begin errors = errors + 1; $display("NG: 偏りが %0d まで広がった", worst); end
    $display("tb_tmds: %0d 件 NG（偏りの最大 %0d）", errors, worst);
    $finish;
  end
endmodule
