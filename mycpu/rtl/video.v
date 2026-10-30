// 表示回路（7.1〜7.3）。720p（1280×720、60Hz、画素クロック 74.25MHz）
//   テキスト：160 × 45 文字、1 文字 8 × 16 ドット。VRAM の 1 文字 2 バイト：文字コード・色（下位 4bit 文字色、上位 4bit 背景色）
//   グラフィック（gmode = 1）：320 × 200・256 色を 3 倍にして真ん中（960 × 600、左上 160, 60）に。まわりは黒。
//     フレームバッファは SDRAM。行ごとに soc に「この行を読んで」と頼み（その行を 3 回出す前の行の頭で）、
//     soc が行バッファ（2 本）に読んでおいたものを読む。色はパレット（soc の中）
//   出力は RGB 各 8bit と同期信号。HDMI（DVI）でも VGA でも、この後ろにつなぐだけ。
module mycpu_video #(
  parameter FONT_HEX = "font8x16.hex"
) (
  input  wire        pclk,
  input  wire        rst,
  output wire [11:0] vaddr,     // VRAM（4 バイト単位）。1 クロック後に vdata
  input  wire [31:0] vdata,
  input  wire        gmode,     // グラフィック（soc の clk 側のレジスタ。ここで揃える）
  output wire [7:0]  gaddr,     // 行バッファ（{行の偶奇, 4 バイト単位の番号}）。1 クロック後に gdata
  input  wire [31:0] gdata,
  output wire [7:0]  paddr,     // パレット。1 クロック後に pdata
  input  wire [23:0] pdata,
  output reg         greq_t,    // 変わるたびに「greq_y の行を読んで」
  output reg  [7:0]  greq_y,
  output reg  [7:0]  r, g, b,
  output reg         hs, vs, de
);
  // 720p のタイミング（CEA-861）
  localparam integer H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_BP = 220, H_TOT = H_ACT + H_FP + H_SYNC + H_BP;
  localparam integer V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_BP = 20,  V_TOT = V_ACT + V_FP + V_SYNC + V_BP;

  // グラフィックの場所（3 倍にして真ん中）
  localparam integer G_X0 = 160, G_Y0 = 60, G_W = 320, G_H = 200;

  reg [10:0] hc;
  reg [9:0]  vc;
  // グラフィックの点の位置（gx・gy）と 3 倍のうち何番目か（gxs・gys）。hc・vc と同じときの値
  reg [8:0]  gx;
  reg [1:0]  gxs;
  reg [7:0]  gy;
  reg [1:0]  gys;
  reg [1:0]  gm_s;               // gmode を画素クロックに揃える
  always @(posedge pclk) begin
    if (rst) begin
      hc <= 11'd0; vc <= 10'd0; gx <= 9'd0; gxs <= 2'd0; gy <= 8'd0; gys <= 2'd0;
      greq_t <= 1'b0; greq_y <= 8'd0; gm_s <= 2'd0;
    end else begin
      gm_s <= {gm_s[0], gmode};
      if (hc == H_TOT - 1) begin
        hc <= 11'd0;
        vc <= vc == V_TOT - 1 ? 10'd0 : vc + 10'd1;
        // 次の行の gy・gys
        if (vc == G_Y0 - 1) begin gy <= 8'd0; gys <= 2'd0; end
        else if (gys == 2'd2) begin gys <= 2'd0; gy <= gy + 8'd1; end
        else gys <= gys + 2'd1;
      end else hc <= hc + 11'd1;
      if (hc == G_X0 - 1) begin gx <= 9'd0; gxs <= 2'd0; end
      else if (gxs == 2'd2) begin gxs <= 2'd0; gx <= gx + 9'd1; end
      else gxs <= gxs + 2'd1;
      // 行の頼み：フレームの最後の行で 0 行目、グラフィックの行の 1 回目の頭で次の行
      if (hc == 11'd0) begin
        if (vc == V_TOT - 1) begin greq_y <= 8'd0; greq_t <= !greq_t; end
        else if (vc >= G_Y0 && vc < G_Y0 + 3 * G_H - 3 && gys == 2'd0) begin greq_y <= gy + 8'd1; greq_t <= !greq_t; end
      end
    end
  end
  wire gact0 = hc >= G_X0 && hc < G_X0 + 3 * G_W && vc >= G_Y0 && vc < G_Y0 + 3 * G_H;
  assign gaddr = {gy[0], gx[8:2]};

  // 段 0：文字の番号 → VRAM の番地
  wire [12:0] ci = vc[9:4] * 8'd160 + hc[10:3];
  assign vaddr = ci[12:1];
  wire act0 = hc < H_ACT && vc < V_ACT;
  wire hs0 = hc >= H_ACT + H_FP && hc < H_ACT + H_FP + H_SYNC;
  wire vs0 = vc >= V_ACT + V_FP && vc < V_ACT + V_FP + V_SYNC;

  // 段 1：VRAM の値 → フォント ROM の番地。行バッファの値 → パレットの番号
  reg       half1, act1, hs1, vs1, gact1;
  reg [2:0] x1;
  reg [3:0] y1;
  reg [1:0] gb1;
  always @(posedge pclk) begin
    half1 <= ci[0]; x1 <= hc[2:0]; y1 <= vc[3:0]; act1 <= act0; hs1 <= hs0; vs1 <= vs0;
    gact1 <= gact0; gb1 <= gx[1:0];
  end
  assign paddr = gdata[{gb1, 3'b000} +: 8];
  wire [15:0] cw = half1 ? vdata[31:16] : vdata[15:0];

  reg [7:0] font [0:4095];
  initial $readmemh(FONT_HEX, font);
  reg [7:0] bits2, attr2;
  reg [2:0] x2;
  reg       act2, hs2, vs2, gact2;
  always @(posedge pclk) begin
    bits2 <= font[{cw[7:0], y1}];
    attr2 <= cw[15:8];
    x2 <= x1; act2 <= act1; hs2 <= hs1; vs2 <= vs1; gact2 <= gact1;
  end

  // 段 2：ドット → 色（標準 16 色）
  function [23:0] palette(input [3:0] c);
    case (c)
      4'd0:  palette = 24'h000000; 4'd1:  palette = 24'h0000AA; 4'd2:  palette = 24'h00AA00; 4'd3:  palette = 24'h00AAAA;
      4'd4:  palette = 24'hAA0000; 4'd5:  palette = 24'hAA00AA; 4'd6:  palette = 24'hAA5500; 4'd7:  palette = 24'hAAAAAA;
      4'd8:  palette = 24'h555555; 4'd9:  palette = 24'h5555FF; 4'd10: palette = 24'h55FF55; 4'd11: palette = 24'h55FFFF;
      4'd12: palette = 24'hFF5555; 4'd13: palette = 24'hFF55FF; 4'd14: palette = 24'hFFFF55; default: palette = 24'hFFFFFF;
    endcase
  endfunction
  wire on = bits2[3'd7 - x2];
  wire [23:0] rgb = gm_s[1] ? (gact2 ? pdata : 24'd0) : palette(on ? attr2[3:0] : attr2[7:4]);
  always @(posedge pclk) begin
    {r, g, b} <= act2 ? rgb : 24'd0;
    de <= act2; hs <= hs2; vs <= vs2;
  end
endmodule
