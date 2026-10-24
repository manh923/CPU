// CPU とメモリ・入出力をつないだもの（4.1 のメモリマップ）
//   0x0000_0000 ROM 16KB（ROM_HEX で中身を決める）
//   0x0001_0000 入出力（UART・タイマー・LED。番地は README）
//   0x0001_8000 テキスト VRAM 16KB（表示回路側にも読み出し口がある）
//   0x0002_0000 内蔵 RAM 32KB
//   SDRAM はまだない（つながっていない番地として扱う）
module mycpu_soc #(
  parameter integer CLK_HZ  = 27_000_000,
  parameter integer BAUD    = 115_200,
  parameter         ROM_HEX = "rom.hex"
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        uart_rxd,
  output wire        uart_txd,
  output reg  [5:0]  led,
  output wire        halted,
  output wire [1:0]  halt_code,
  // 表示回路からの VRAM 読み出し（4 バイト単位の番地、1 クロック後にデータ）
  input  wire        vclk,
  input  wire [11:0] vaddr,
  output wire [31:0] vdata
);
  wire [31:0] addr, wdata, rdata_cpu;
  wire [3:0]  wstrb;
  wire        valid;
  reg         ready, fault;
  wire [7:0]  irq;

  mycpu_cpu cpu (
    .clk(clk), .rst(rst),
    .bus_addr(addr), .bus_wdata(wdata), .bus_wstrb(wstrb), .bus_valid(valid),
    .bus_ready(ready), .bus_rdata(rdata_cpu), .bus_fault(fault),
    .irq(irq), .halted(halted), .halt_code(halt_code)
  );

  // ---- 番地の振り分け ----
  wire sel_rom  = addr[31:14] == 18'h0;          // 0x0000_0000〜0x0000_3FFF
  wire sel_io   = addr[31:15] == 17'h2;          // 0x0001_0000〜0x0001_7FFF
  wire sel_vram = addr[31:14] == 18'h6;          // 0x0001_8000〜0x0001_BFFF
  wire sel_ram  = addr[31:15] == 17'h4;          // 0x0002_0000〜0x0002_7FFF
  wire start = valid && !ready;
  wire wr = wstrb != 4'd0;

  // ---- メモリ ----
  reg [31:0] rom [0:4095];
  initial $readmemh(ROM_HEX, rom);
  reg [31:0] rom_q;
  always @(posedge clk) rom_q <= rom[addr[13:2]];

  wire [31:0] ram_q, vram_q;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : lane
      mycpu_bram #(.AW(13)) ram (
        .clk(clk), .we(start && sel_ram && wstrb[g]), .addr(addr[14:2]),
        .din(wdata[8*g +: 8]), .dout(ram_q[8*g +: 8])
      );
      mycpu_dpram #(.AW(12)) vram (
        .clka(clk), .wea(start && sel_vram && wstrb[g]), .addra(addr[13:2]),
        .dina(wdata[8*g +: 8]), .douta(vram_q[8*g +: 8]),
        .clkb(vclk), .addrb(vaddr), .doutb(vdata[8*g +: 8])
      );
    end
  endgenerate

  // ---- 入出力（仮決め。lib/isa.js の IO と同じ） ----
  localparam [14:0] IO_UART_TX = 15'h00, IO_UART_STATUS = 15'h04, IO_UART_RX = 15'h08,
                    IO_TIMER_COUNT = 15'h10, IO_TIMER_CMP = 15'h14, IO_TIMER_CTRL = 15'h18,
                    IO_LED = 15'h20;
  wire [14:0] io_off = {addr[14:2], 2'b00};
  // 書き込み：レジスタの先頭バイトを含むときだけ効く。書かないバイトは 0
  wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};
  wire [31:0] io_w = wdata & wmask;
  wire io_we = start && sel_io && wstrb[0];

  wire       tx_ready, rx_valid;
  wire [7:0] rx_data;
  mycpu_uart #(.DIV(CLK_HZ / BAUD)) uart (
    .clk(clk), .rst(rst),
    .tx_we(io_we && io_off == IO_UART_TX), .tx_data(io_w[7:0]), .tx_ready(tx_ready), .txd(uart_txd),
    .rx_re(start && sel_io && !wr && io_off == IO_UART_RX), .rx_data(rx_data), .rx_valid(rx_valid),
    .rxd(uart_rxd)
  );

  // タイマー：1µs ごとに増える 32bit カウンタ。COUNT − CMP が 0 以上（符号付き）で割り込み 1
  localparam integer US_DIV = CLK_HZ / 1_000_000;
  reg [31:0] t_count, t_cmp;
  reg        t_en;
  reg [15:0] t_pre;
  wire [31:0] t_diff = t_count - t_cmp;
  wire t_pending = t_en && !t_diff[31];
  assign irq = {6'd0, t_pending, rx_valid};

  reg [31:0] io_q;
  always @(posedge clk) begin
    if (rst) begin
      t_count <= 32'd0; t_cmp <= 32'd0; t_en <= 1'b0; t_pre <= 16'd0; led <= 6'd0;
    end else begin
      if (t_pre == US_DIV - 1) begin t_pre <= 16'd0; t_count <= t_count + 32'd1; end
      else t_pre <= t_pre + 16'd1;
      if (io_we) case (io_off)
        IO_TIMER_COUNT: begin t_count <= io_w; t_pre <= 16'd0; end
        IO_TIMER_CMP:   t_cmp <= io_w;
        IO_TIMER_CTRL:  t_en <= io_w[0];
        IO_LED:         led <= io_w[5:0];
        default: ;
      endcase
    end
    case (io_off)
      IO_UART_STATUS: io_q <= {30'd0, rx_valid, tx_ready};
      IO_UART_RX:     io_q <= rx_valid ? {24'd0, rx_data} : 32'd0;
      IO_TIMER_COUNT: io_q <= t_count;
      IO_TIMER_CMP:   io_q <= t_cmp;
      IO_TIMER_CTRL:  io_q <= {30'd0, t_pending, t_en};
      IO_LED:         io_q <= {26'd0, led};
      default:        io_q <= 32'd0;
    endcase
  end

  // ---- バスの応答（どのアクセスも 2 クロック） ----
  reg [1:0] which;   // 0 = ROM、1 = 入出力、2 = VRAM、3 = RAM
  always @(posedge clk) begin
    if (rst) begin
      ready <= 1'b0; fault <= 1'b0; which <= 2'd0;
    end else begin
      ready <= start;
      if (start) begin
        which <= sel_io ? 2'd1 : sel_vram ? 2'd2 : sel_ram ? 2'd3 : 2'd0;
        fault <= !(sel_rom || sel_io || sel_vram || sel_ram) || (sel_rom && wr);
      end
    end
  end
  assign rdata_cpu = which == 2'd0 ? rom_q : which == 2'd1 ? io_q : which == 2'd2 ? vram_q : ram_q;
endmodule

// 1 ポートの RAM（BSRAM になる書き方）
module mycpu_bram #(parameter integer AW = 13) (
  input  wire          clk,
  input  wire          we,
  input  wire [AW-1:0] addr,
  input  wire [7:0]    din,
  output reg  [7:0]    dout
);
  reg [7:0] mem [0:(1 << AW) - 1];
`ifdef MYCPU_SIM
  integer i;   // シミュレーションでは 0 にしておく（実機の BSRAM も 0 から始まる）
  initial for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 8'd0;
`endif
  always @(posedge clk) begin
    if (we) mem[addr] <= din;
    dout <= mem[addr];
  end
endmodule

// 2 ポートの RAM（A は CPU が読み書き、B は表示回路が読むだけ。クロックは別）
module mycpu_dpram #(parameter integer AW = 12) (
  input  wire          clka,
  input  wire          wea,
  input  wire [AW-1:0] addra,
  input  wire [7:0]    dina,
  output reg  [7:0]    douta,
  input  wire          clkb,
  input  wire [AW-1:0] addrb,
  output reg  [7:0]    doutb
);
  reg [7:0] mem [0:(1 << AW) - 1];
`ifdef MYCPU_SIM
  integer i;   // シミュレーションでは 0 にしておく（実機の BSRAM も 0 から始まる）
  initial for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 8'd0;
`endif
  always @(posedge clka) begin
    if (wea) mem[addra] <= dina;
    douta <= mem[addra];
  end
  always @(posedge clkb) doutb <= mem[addrb];
endmodule
