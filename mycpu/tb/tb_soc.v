// SoC 全体のテストベンチ（Icarus Verilog 用）。test/run.js から使う。
//   コンパイル時：-Ptb.ROM_EVEN_HEX="prog_even.hex" -Ptb.ROM_ODD_HEX="prog_odd.hex" -Ptb.FONT_HEX="font8x16.hex"
//   実行時：+uart=出力 +regs=出力 [+rx=入力] [+ppm=出力] [+max=クロック数]
// 止まったら（HLT など）レジスタ一覧を lib/cpu.js の dumpRegs と同じ書式で書く。
// +ppm があれば、止まった後の 1 フレームを表示回路から取り込んで PPM にする。
`timescale 1ns / 1ps
module tb;
  parameter ROM_EVEN_HEX = "";
  parameter ROM_ODD_HEX  = "";
  parameter FONT_HEX = "";
  parameter SD_HEX   = "";        // SD カードの中身（空ならカードなし）
  parameter integer SD_SECTORS = 8192;
  // シミュレーションを速くするため、クロック 1MHz（タイマーの 1µs = 1 クロック）・UART 250kbps（1 bit = 4 クロック）とみなす
  localparam integer CLK_HZ = 1_000_000, BAUD = 250_000, BIT = CLK_HZ / BAUD;

  reg clk = 1'b0, vclk = 1'b0, rst = 1'b1, rxd = 1'b1;
  always #5 clk = ~clk;
  always #2 vclk = ~vclk;

  wire        txd, halted;
  wire [1:0]  halt_code;
  wire [5:0]  led;
  wire [11:0] vaddr;
  wire [31:0] vdata;
  wire sd_sclk, sd_mosi, sd_miso, sd_cs_n;
  sd_model #(.DISK_HEX(SD_HEX), .SECTORS(SD_SECTORS)) sd (.sclk(sd_sclk), .mosi(sd_mosi), .cs_n(sd_cs_n), .miso(sd_miso));
  // SDRAM：クロック数で見たタイミングは実機（27MHz）と同じにする
  wire dr_clk, dr_cke, dr_cs_n, dr_ras_n, dr_cas_n, dr_we_n;
  wire [10:0] dr_a;
  wire [1:0]  dr_ba;
  wire [3:0]  dr_dqm;
  wire [31:0] dr_dq;
  sdram_model #(.SDRAM_HZ(27_000_000)) sdram (
    .clk(dr_clk), .cke(dr_cke), .cs_n(dr_cs_n), .ras_n(dr_ras_n), .cas_n(dr_cas_n), .we_n(dr_we_n),
    .ba(dr_ba), .a(dr_a), .dqm(dr_dqm), .dq(dr_dq)
  );
  mycpu_soc #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .ROM_EVEN_HEX(ROM_EVEN_HEX), .ROM_ODD_HEX(ROM_ODD_HEX), .SDRAM_HZ(27_000_000)) soc (
    .clk(clk), .rst(rst), .uart_rxd(rxd), .uart_txd(txd), .led(led),
    .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
    .sdram_clk(dr_clk), .sdram_cke(dr_cke), .sdram_cs_n(dr_cs_n), .sdram_ras_n(dr_ras_n), .sdram_cas_n(dr_cas_n),
    .sdram_we_n(dr_we_n), .sdram_a(dr_a), .sdram_ba(dr_ba), .sdram_dqm(dr_dqm), .sdram_dq(dr_dq),
    .halted(halted), .halt_code(halt_code), .vclk(vclk), .vaddr(vaddr), .vdata(vdata),
    .gaddr(gaddr), .gdata(gdata), .paddr(paddr), .pdata(pdata), .gmode(gmode), .greq_t(greq_t), .greq_y(greq_y)
  );
  wire [7:0] r, g, b;
  wire hs, vs, de;
  wire [7:0]  gaddr, paddr, greq_y;
  wire [31:0] gdata;
  wire [23:0] pdata;
  wire        gmode, greq_t;
  mycpu_video #(.FONT_HEX(FONT_HEX)) video (
    .pclk(vclk), .rst(rst), .vaddr(vaddr), .vdata(vdata), .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .de(de),
    .gmode(gmode), .gaddr(gaddr), .gdata(gdata), .paddr(paddr), .pdata(pdata), .greq_t(greq_t), .greq_y(greq_y)
  );

  reg [1023:0] path;
  integer fu, fr, fx, fp, max, cycles, i, c, n;

  // ---- UART 送信を読み取る ----
  reg [7:0] ch;
  initial begin
    forever begin
      @(negedge txd);
      repeat (BIT / 2) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        repeat (BIT) @(posedge clk);
        ch[i] = txd;
      end
      repeat (BIT) @(posedge clk);
      if (fu) $fwrite(fu, "%c", ch);
    end
  end

  // ---- UART 受信に流し込む ----
  task send(input [7:0] v);
    integer j;
    begin
      rxd = 1'b0; repeat (BIT) @(posedge clk);
      for (j = 0; j < 8; j = j + 1) begin rxd = v[j]; repeat (BIT) @(posedge clk); end
      rxd = 1'b1; repeat (BIT * 40) @(posedge clk);   // 1 文字ごとに間をあける
    end
  endtask

  // +trace=ファイル：命令を実行するたびに番地を書く（lib/cpu.js の trace と比べる用）
  integer ft;
  initial begin
    ft = 0;
    if ($value$plusargs("trace=%s", path)) ft = $fopen(path, "w");
  end
  always @(posedge clk) if (ft && soc.cpu.x_trace) $fwrite(ft, "%08x\n", soc.cpu.pc);

  task dump_regs;
    begin
      $fwrite(fr, "pc=%08x sp=%08x lr=%08x\n", soc.cpu.pc, soc.cpu.sp, soc.cpu.lr);
      $fwrite(fr, "epc=%08x cause=%08x evec=%08x status=%08x\n", soc.cpu.epc, soc.cpu.cause, soc.cpu.evec, soc.cpu.status);
      $fwrite(fr, "p1-p7=%b%b%b%b%b%b%b\n", soc.cpu.pr[1], soc.cpu.pr[2], soc.cpu.pr[3], soc.cpu.pr[4],
              soc.cpu.pr[5], soc.cpu.pr[6], soc.cpu.pr[7]);
      for (i = 0; i < 16; i = i + 4)
        $fwrite(fr, "r%0d=%08x r%0d=%08x r%0d=%08x r%0d=%08x\n", 16 + i, soc.cpu.gpr[i], 17 + i, soc.cpu.gpr[i + 1],
                18 + i, soc.cpu.gpr[i + 2], 19 + i, soc.cpu.gpr[i + 3]);
    end
  endtask

  initial begin
    fu = 0; fr = 0; fx = 0; fp = 0;
    if ($value$plusargs("uart=%s", path)) fu = $fopen(path, "wb");
    if ($value$plusargs("regs=%s", path)) fr = $fopen(path, "w");
    if (!$value$plusargs("max=%d", max)) max = 20_000_000;
    repeat (4) @(posedge clk);
    rst = 1'b0;

    if ($value$plusargs("rx=%s", path)) begin
      fx = $fopen(path, "rb");
      repeat (BIT * 200) @(posedge clk);
      c = $fgetc(fx);
      while (c >= 0 && !halted) begin
        // 人がキーを打つのと同じく、前の文字を CPU が読んでから次を送る（受信 FIFO をあふれさせない）
        while (soc.uart.rw != soc.uart.rr) @(posedge clk);
        send(c[7:0]);
        c = $fgetc(fx);
      end
    end
  end

  initial begin
    cycles = 0;
    @(negedge rst);
    while (halted !== 1'b1 && cycles < max) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    repeat (BIT * 10 * 20) @(posedge clk);   // UART の送信が終わるのを待つ
    if (!halted) $display("tb: %0d クロックで打ち切り", max);
    else $display("tb: 停止 halt_code=%0d（%0d クロック）", halt_code, cycles);
    $display("tb: SDRAM 読み出し %0d 回・書き込み %0d 回、タイミング違反 %0d 件", sdram.reads, sdram.writes, sdram.errors);
    if (fr) begin dump_regs; $fclose(fr); end
    if (ft) $fclose(ft);
    if (fu) $fclose(fu);

    if ($value$plusargs("ppm=%s", path)) begin
      fp = $fopen(path, "wb");
      $fwrite(fp, "P6\n1280 720\n255\n");
      @(posedge vs);                         // 垂直同期の後から 1 フレーム分
      n = 0;
      while (n < 1280 * 720) begin
        @(posedge vclk);
        if (de) begin
          $fwrite(fp, "%c%c%c", r, g, b);
          n = n + 1;
        end
      end
      $fclose(fp);
    end
    $finish;
  end
endmodule
