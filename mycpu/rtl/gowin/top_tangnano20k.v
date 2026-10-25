// Tang Nano 20K（GW2AR-LV18QN88C8/I7）のトップ
//   CPU は 27MHz の水晶をそのまま使う。画面は PLL で 371.25MHz を作り、5 分周した 74.25MHz を画素クロックにする。
//   HDMI 端子からは DVI 信号（音声なし）を出す。HDMI モニタにそのまま映る。
// Gowin 専用の部品（rPLL・CLKDIV・OSER10・ELVDS_OBUF）を使うのはこのファイルだけ。
// ※ボードでの動作確認はまだ。PLL の設定値とピンは Sipeed の HDMI 例と同じ値にしてある。
module top_tangnano20k (
  input  wire       clk27,       // 27MHz
  input  wire       btn_rst,     // S1：押すとリセット
  input  wire       uart_rx,     // USB-UART（BL616）から
  output wire       uart_tx,
  output wire [5:0] led_n,       // LED（0 で点灯）
  output wire       sd_clk,      // microSD（SPI モードで使う）
  output wire       sd_cmd,      //   MOSI
  input  wire       sd_dat0,     //   MISO
  output wire       sd_dat3,     //   CS
  output wire       sd_dat1,     //   SPI では使わない（1 にしておく）
  output wire       sd_dat2,
  output wire       tmds_clk_p, tmds_clk_n,
  output wire [2:0] tmds_d_p, tmds_d_n
);
  // ---- クロック ----
  wire clk_ser, pll_lock, clk_pix;
  rPLL #(
    .FCLKIN("27"), .DEVICE("GW2AR-18C"),
    .IDIV_SEL(3), .FBDIV_SEL(54), .ODIV_SEL(2),   // 27 ÷ 4 × 55 = 371.25MHz（VCO 742.5MHz）
    .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
    .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
    .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
    .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
    .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
  ) pll (
    .CLKOUT(clk_ser), .LOCK(pll_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
    .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
    .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0)
  );
  CLKDIV #(.DIV_MODE("5"), .GSREN("false")) pixdiv (
    .CLKOUT(clk_pix), .HCLKIN(clk_ser), .RESETN(pll_lock), .CALIB(1'b0)
  );

  // ---- リセット（電源投入時とボタン） ----
  reg [15:0] por = 16'd0;
  reg        rst = 1'b1;
  always @(posedge clk27) begin
    if (btn_rst) begin por <= 16'd0; rst <= 1'b1; end
    else if (por != 16'hFFFF) por <= por + 16'd1;
    else rst <= 1'b0;
  end
  reg [1:0] prst = 2'b11;   // 画素クロック側へ渡す
  always @(posedge clk_pix) prst <= {prst[0], rst || !pll_lock};

  // ---- CPU とメモリ ----
  wire [11:0] vaddr;
  wire [31:0] vdata;
  wire [5:0]  led;
  wire        halted;
  wire [1:0]  halt_code;
  mycpu_soc #(.CLK_HZ(27_000_000), .BAUD(115_200), .ROM_HEX("rom.hex")) soc (
    .clk(clk27), .rst(rst), .uart_rxd(uart_rx), .uart_txd(uart_tx),
    .sd_sclk(sd_clk), .sd_mosi(sd_cmd), .sd_miso(sd_dat0), .sd_cs_n(sd_dat3),
    .led(led), .halted(halted), .halt_code(halt_code),
    .vclk(clk_pix), .vaddr(vaddr), .vdata(vdata)
  );
  assign sd_dat1 = 1'b1;
  assign sd_dat2 = 1'b1;

  // 止まったら LED5・LED4 に理由を出す（01 = HLT、10 = 不正命令、11 = バスエラー）
  assign led_n = ~(halted ? {halt_code, led[3:0]} : led);

  // ---- 画面 ----
  wire [7:0] r, g, b;
  wire hs, vs, de;
  mycpu_video #(.FONT_HEX("font8x16.hex")) video (
    .pclk(clk_pix), .rst(prst[1]), .vaddr(vaddr), .vdata(vdata),
    .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .de(de)
  );

  wire [9:0] t0, t1, t2;
  mycpu_tmds enc_b (.clk(clk_pix), .de(de), .d(b), .c({vs, hs}), .q(t0));
  mycpu_tmds enc_g (.clk(clk_pix), .de(de), .d(g), .c(2'b00),    .q(t1));
  mycpu_tmds enc_r (.clk(clk_pix), .de(de), .d(r), .c(2'b00),    .q(t2));

  dvi_lane lane0 (.pclk(clk_pix), .fclk(clk_ser), .rst(prst[1]), .d(t0),           .p(tmds_d_p[0]), .n(tmds_d_n[0]));
  dvi_lane lane1 (.pclk(clk_pix), .fclk(clk_ser), .rst(prst[1]), .d(t1),           .p(tmds_d_p[1]), .n(tmds_d_n[1]));
  dvi_lane lane2 (.pclk(clk_pix), .fclk(clk_ser), .rst(prst[1]), .d(t2),           .p(tmds_d_p[2]), .n(tmds_d_n[2]));
  dvi_lane lanec (.pclk(clk_pix), .fclk(clk_ser), .rst(prst[1]), .d(10'b0000011111), .p(tmds_clk_p), .n(tmds_clk_n));
endmodule

// 10bit を 1 本の差動線に順番に出す（下位 bit から）
module dvi_lane (
  input  wire       pclk,
  input  wire       fclk,
  input  wire       rst,
  input  wire [9:0] d,
  output wire       p,
  output wire       n
);
  wire s;
  OSER10 #(.GSREN("false"), .LSREN("true")) ser (
    .Q(s), .D0(d[0]), .D1(d[1]), .D2(d[2]), .D3(d[3]), .D4(d[4]),
    .D5(d[5]), .D6(d[6]), .D7(d[7]), .D8(d[8]), .D9(d[9]),
    .PCLK(pclk), .FCLK(fclk), .RESET(rst)
  );
  ELVDS_OBUF buf_ (.I(s), .O(p), .OB(n));
endmodule
