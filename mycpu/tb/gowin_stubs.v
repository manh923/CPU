// Gowin 専用部品の代わり（中身なし）。トップ（rtl/gowin/top_tangnano20k.v）が
// つながりとして正しいか、iverilog でコンパイルだけ確かめるために使う。実機では使わない。
module rPLL #(
  parameter FCLKIN = "27", parameter DEVICE = "", parameter integer IDIV_SEL = 0,
  parameter integer FBDIV_SEL = 0, parameter integer ODIV_SEL = 0,
  parameter DYN_IDIV_SEL = "false", parameter DYN_FBDIV_SEL = "false", parameter DYN_ODIV_SEL = "false",
  parameter PSDA_SEL = "0000", parameter DYN_DA_EN = "false", parameter DUTYDA_SEL = "1000",
  parameter CLKOUT_FT_DIR = 1'b1, parameter CLKOUTP_FT_DIR = 1'b1,
  parameter integer CLKOUT_DLY_STEP = 0, parameter integer CLKOUTP_DLY_STEP = 0,
  parameter CLKFB_SEL = "internal", parameter CLKOUT_BYPASS = "false", parameter CLKOUTP_BYPASS = "false",
  parameter CLKOUTD_BYPASS = "false", parameter integer DYN_SDIV_SEL = 2,
  parameter CLKOUTD_SRC = "CLKOUT", parameter CLKOUTD3_SRC = "CLKOUT"
) (
  output CLKOUT, output LOCK, output CLKOUTP, output CLKOUTD, output CLKOUTD3,
  input RESET, input RESET_P, input CLKIN, input CLKFB,
  input [5:0] FBDSEL, input [5:0] IDSEL, input [5:0] ODSEL, input [3:0] PSDA, input [3:0] DUTYDA, input [3:0] FDLY
);
  assign CLKOUT = CLKIN; assign LOCK = 1'b1;
  assign CLKOUTP = CLKIN; assign CLKOUTD = CLKIN; assign CLKOUTD3 = CLKIN;
endmodule

module CLKDIV #(parameter DIV_MODE = "2", parameter GSREN = "false") (
  output CLKOUT, input HCLKIN, input RESETN, input CALIB
);
  assign CLKOUT = HCLKIN;
endmodule

module OSER10 #(parameter GSREN = "false", parameter LSREN = "true") (
  output Q, input D0, input D1, input D2, input D3, input D4,
  input D5, input D6, input D7, input D8, input D9,
  input PCLK, input FCLK, input RESET
);
  assign Q = D0;
endmodule

module ELVDS_OBUF (input I, output O, output OB);
  assign O = I; assign OB = ~I;
endmodule
