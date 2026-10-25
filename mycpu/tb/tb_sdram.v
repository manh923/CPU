// SDRAM の制御回路だけのテストベンチ（Icarus Verilog 用）。test/run.js から使う。
//   27MHz で動かし、ランダムな番地・バイトの書き込みと読み出しを繰り返して、覚えておいた値と比べる。
//   バースト読み出し（16 語）も、16 語を書いてから読んで比べる。
//   SDRAM のモデル（tb/sdram_model.v）がタイミング違反を見つけてもエラー
`timescale 1ns / 1ps
module tb_sdram;
  parameter integer N = 20000;
  reg clk = 1'b0, rst = 1'b1;
  always #18.518 clk = ~clk;        // 27MHz

  reg         req = 1'b0;
  reg  [20:0] waddr = 21'd0;
  reg  [3:0]  wstrb = 4'd0;
  reg  [31:0] wdata = 32'd0;
  reg         burst = 1'b0;
  wire        ack, ready_init, bvalid;
  wire [31:0] rdata;
  wire sclk, cke, cs_n, ras_n, cas_n, we_n;
  wire [10:0] a;
  wire [1:0]  ba;
  wire [3:0]  dqm;
  wire [31:0] dq;
  mycpu_sdram #(.SDRAM_HZ(27_000_000)) ctl (
    .clk(clk), .rst(rst), .req(req), .waddr(waddr), .wstrb(wstrb), .wdata(wdata), .burst(burst), .ack(ack), .bvalid(bvalid), .rdata(rdata),
    .ready_init(ready_init),
    .sdram_clk(sclk), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
    .sdram_a(a), .sdram_ba(ba), .sdram_dqm(dqm), .sdram_dq(dq)
  );
  sdram_model #(.SDRAM_HZ(27_000_000)) m (
    .clk(sclk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .ba(ba), .a(a), .dqm(dqm), .dq(dq)
  );

  // 使う番地を 256 個に絞る（同じ番地への読み書きが何度も起きるように）。行・バンク・列はばらばら
  reg [20:0] addrs [0:255];
  reg [31:0] shadow [0:255];
  integer i, k, ng = 0, nr = 0, nw = 0, waits, maxwait = 0, maxburst = 0, t0;
  reg [20:0] bbase;
  reg [31:0] bwant [0:15];
  reg [31:0] v;

  task access(input [20:0] ad, input [3:0] st, input [31:0] d, output [31:0] q);
    begin
      @(posedge clk); #1;
      req = 1'b1; waddr = ad; wstrb = st; wdata = d;
      @(posedge clk); #1;
      req = 1'b0;
      waits = 1;
      while (!ack) begin @(posedge clk); #1; waits = waits + 1; end
      q = rdata;
      if (waits > maxwait) maxwait = waits;
      // CPU と同じく、ack の後すぐには次を出さない
      repeat ($urandom % 3) @(posedge clk);
    end
  endtask

  initial begin
    for (i = 0; i < 256; i = i + 1) begin
      addrs[i] = i == 0 ? 21'd0 : i == 1 ? 21'h1FFFFF : $urandom;
      shadow[i] = 32'h0;
    end
    repeat (4) @(posedge clk);
    rst = 1'b0;
    t0 = 0;
    while (!ready_init) begin @(posedge clk); t0 = t0 + 1; end
    for (i = 0; i < N; i = i + 1) begin
      k = $urandom % 256;
      if ($urandom % 2) begin
        v = $urandom;
        wstrb = ($urandom % 3 == 0) ? (4'd1 << ($urandom % 4)) : 4'hF;
        access(addrs[k], wstrb, v, v);
        nw = nw + 1;
        if (wstrb[0]) shadow[k][7:0] = wdata[7:0];
        if (wstrb[1]) shadow[k][15:8] = wdata[15:8];
        if (wstrb[2]) shadow[k][23:16] = wdata[23:16];
        if (wstrb[3]) shadow[k][31:24] = wdata[31:24];
      end else begin
        access(addrs[k], 4'd0, 32'd0, v);
        nr = nr + 1;
        if (v !== shadow[k]) begin
          ng = ng + 1;
          if (ng <= 10) $display("tb_sdram: 番地 %06x：読んだ値 %08x、正しい値 %08x", addrs[k], v, shadow[k]);
        end
      end
    end
    // バースト読み出し：16 語の境目にランダムな値を書き、続けて読む
    for (i = 0; i < 300; i = i + 1) begin
      bbase = $urandom & 21'h1FFFF0;
      for (k = 0; k < 16; k = k + 1) begin
        bwant[k] = $urandom;
        access(bbase + k, 4'hF, bwant[k], v);
      end
      @(posedge clk); #1;
      req = 1'b1; burst = 1'b1; waddr = bbase; wstrb = 4'd0;
      @(posedge clk); #1;
      req = 1'b0; burst = 1'b0;
      k = 0; waits = 1;
      while (!ack) begin
        if (bvalid) begin
          if (k >= 16 || rdata !== bwant[k]) begin
            ng = ng + 1;
            if (ng <= 10) $display("tb_sdram: バースト %06x の %0d 語目：%08x、正しい値 %08x", bbase, k, rdata, bwant[k]);
          end
          k = k + 1;
        end
        @(posedge clk); #1; waits = waits + 1;
      end
      if (bvalid) begin if (rdata !== bwant[k]) ng = ng + 1; k = k + 1; end
      if (k != 16) begin ng = ng + 1; $display("tb_sdram: バーストで %0d 語しか来ない", k); end
      if (waits > maxburst) maxburst = waits;
    end
    $display("tb_sdram: 初期化 %0d クロック、書き込み %0d 回・読み出し %0d 回（いちばん長い待ち %0d クロック）、バースト 16 語 %0d クロック",
             t0, nw, nr, maxwait, maxburst);
    $display("tb_sdram: モデルのリフレッシュ %0d 回、タイミング違反 %0d 件", m.nrefs, m.errors);
    $display("tb_sdram: %0d 件 NG", ng + m.errors);
    $finish;
  end
endmodule
