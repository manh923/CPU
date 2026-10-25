// CPU とメモリ・入出力をつないだもの（4.1 のメモリマップ）
//   0x0000_0000 ROM 16KB（中身は ROM_EVEN_HEX・ROM_ODD_HEX。偶数番目と奇数番目の 4 バイトに分けたもの）
//   0x0001_0000 入出力（UART・タイマー・LED。番地は README）
//   0x0001_8000 テキスト VRAM 16KB（表示回路側にも読み出し口がある）
//   0x0002_0000 内蔵 RAM 48KB
//   0x0100_0000 SDRAM 8MB（rtl/sdram.v。1 回のアクセスに 4〜9 クロックかかる）
// CPU とは「命令の口」と「データの口」の 2 つでつなぐ（rtl/cpu.v の先頭に約束事）。
// ROM と内蔵 RAM は、偶数番目の 4 バイトと奇数番目の 4 バイトで別のメモリにしてあるので、
// 命令の口はどこから始まる 8 バイトでも 1 クロックで読める。どちらのメモリも 2 ポートで、
// 片方を命令の口、もう片方をデータの口が使う。
module mycpu_soc #(
  parameter integer CLK_HZ       = 27_000_000,
  parameter integer BAUD         = 115_200,
  parameter         ROM_EVEN_HEX = "rom_even.hex",
  parameter         ROM_ODD_HEX  = "rom_odd.hex",
  parameter integer SDRAM_HZ     = CLK_HZ       // SDRAM のタイミングの計算に使う実際の周波数
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        uart_rxd,
  output wire        uart_txd,
  output reg  [5:0]  led,
  // SD カード（SPI モード 0）
  output wire        sd_sclk,
  output wire        sd_mosi,
  input  wire        sd_miso,
  output wire        sd_cs_n,
  // SDRAM
  output wire        sdram_clk,
  output wire        sdram_cke,
  output wire        sdram_cs_n,
  output wire        sdram_ras_n,
  output wire        sdram_cas_n,
  output wire        sdram_we_n,
  output wire [10:0] sdram_a,
  output wire [1:0]  sdram_ba,
  output wire [3:0]  sdram_dqm,
  inout  wire [31:0] sdram_dq,
  output wire        halted,
  output wire [1:0]  halt_code,
  // 表示回路からの VRAM 読み出し（4 バイト単位の番地、1 クロック後にデータ）
  input  wire        vclk,
  input  wire [11:0] vaddr,
  output wire [31:0] vdata
);
  // ---- CPU ----
  wire        i_req, d_req;
  wire [31:0] i_addr, d_addr, d_wdata;
  wire [3:0]  d_wstrb;
  wire        i_gnt, d_gnt, d_err;
  reg         i_rvalid, d_rvalid;
  wire [63:0] i_rdata;
  wire [31:0] d_rdata;
  reg  [1:0]  i_err;
  wire [7:0]  irq;

  mycpu_cpu cpu (
    .clk(clk), .rst(rst),
    .i_req(i_req), .i_addr(i_addr), .i_gnt(i_gnt), .i_rvalid(i_rvalid), .i_rdata(i_rdata), .i_err(i_err),
    .d_req(d_req), .d_addr(d_addr), .d_wstrb(d_wstrb), .d_wdata(d_wdata),
    .d_gnt(d_gnt), .d_err(d_err), .d_rvalid(d_rvalid), .d_rdata(d_rdata),
    .irq(irq), .halted(halted), .halt_code(halt_code)
  );

  // ---- 番地の振り分け ----
  function in_rom(input [31:0] a);   in_rom   = a[31:14] == 18'h0;                        endfunction // 0x0000_0000〜0x0000_3FFF
  function in_io(input [31:0] a);    in_io    = a[31:15] == 17'h2;                        endfunction // 0x0001_0000〜0x0001_7FFF
  function in_vram(input [31:0] a);  in_vram  = a[31:14] == 18'h6;                        endfunction // 0x0001_8000〜0x0001_BFFF
  function in_ram(input [31:0] a);   in_ram   = a[31:16] == 16'h2 && a[15:14] != 2'b11;   endfunction // 0x0002_0000〜0x0002_BFFF
  function in_sdram(input [31:0] a); in_sdram = a[31:23] == 9'h2;                         endfunction // 0x0100_0000〜0x017F_FFFF

  // データの口
  wire sel_rom = in_rom(d_addr), sel_io = in_io(d_addr), sel_vram = in_vram(d_addr);
  wire sel_ram = in_ram(d_addr), sel_sdram = in_sdram(d_addr);
  wire wr = d_wstrb != 4'd0;
  assign d_err = d_req && (!(sel_rom || sel_io || sel_vram || sel_ram || sel_sdram) || (sel_rom && wr));
  wire d_go = d_req && d_gnt && !d_err;         // このクロックで受け付けた
  wire d_odd = d_addr[2];                        // 奇数番目の 4 バイト

  // 命令の口（i_addr とその次の 4 バイト）
  wire [31:0] i_addr1 = i_addr + 32'd4;
  wire i_rom = in_rom(i_addr), i_ram = in_ram(i_addr), i_sdram = in_sdram(i_addr);
  wire i_go = i_req && i_gnt;

  // ---- ROM（偶数・奇数の 2 つ。どちらも読み出し口が 2 つ） ----
  //   命令の口：番地の 4 バイト目が偶数なら偶数側の w/2 と奇数側の w/2、奇数なら奇数側の w/2 と偶数側の w/2+1
  wire [11:0] i_rw  = i_addr[13:2];
  wire [11:0] i_rw1 = i_rw + 12'd1;
  wire [31:0] rom_ie, rom_io, rom_de, rom_do;
  mycpu_rom2 #(.HEX(ROM_EVEN_HEX), .AW(11)) rom_e (
    .clk(clk), .addra(i_rw1[11:1]), .douta(rom_ie), .addrb(d_addr[13:3]), .doutb(rom_de));
  mycpu_rom2 #(.HEX(ROM_ODD_HEX), .AW(11)) rom_o (
    .clk(clk), .addra(i_rw[11:1]), .douta(rom_io), .addrb(d_addr[13:3]), .doutb(rom_do));

  // ---- 内蔵 RAM（偶数・奇数 × 4 バイト。どれも 2 ポート：A は命令の口が読むだけ、B はデータの口） ----
  wire [13:0] i_mw  = i_addr[15:2];
  wire [13:0] i_mw1 = i_mw + 14'd1;
  wire [31:0] ram_ie, ram_io, ram_de, ram_do, vram_q;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : lane
      mycpu_tdpram #(.AW(13), .DEPTH(6144)) ram_e (
        .clk(clk), .addra(i_mw1[13:1]), .douta(ram_ie[8*g +: 8]),
        .web(d_go && sel_ram && !d_odd && d_wstrb[g]), .addrb(d_addr[15:3]), .dinb(d_wdata[8*g +: 8]),
        .doutb(ram_de[8*g +: 8])
      );
      mycpu_tdpram #(.AW(13), .DEPTH(6144)) ram_o (
        .clk(clk), .addra(i_mw[13:1]), .douta(ram_io[8*g +: 8]),
        .web(d_go && sel_ram && d_odd && d_wstrb[g]), .addrb(d_addr[15:3]), .dinb(d_wdata[8*g +: 8]),
        .doutb(ram_do[8*g +: 8])
      );
      mycpu_dpram #(.AW(12)) vram (
        .clka(clk), .wea(d_go && sel_vram && d_wstrb[g]), .addra(d_addr[13:2]),
        .dina(d_wdata[8*g +: 8]), .douta(vram_q[8*g +: 8]),
        .clkb(vclk), .addrb(vaddr), .doutb(vdata[8*g +: 8])
      );
    end
  endgenerate

  // ---- SDRAM：データの口を先に。命令の口は 4 バイトずつ 2 回読む ----
  wire        sdr_ack;
  wire [31:0] sdram_q;
  reg         sdr_busy;          // 制御回路が動いている
  reg         sdr_who;           // 0 = データの口、1 = 命令の口
  reg         sdr_second;        // 命令の口の 2 回目
  reg  [31:0] sdr_iaddr, sdr_w0;
  wire d_sdram = d_req && sel_sdram && !d_err;
  wire i_sdram_req = i_req && i_sdram;
  assign d_gnt = !d_sdram || !sdr_busy;
  assign i_gnt = !i_sdram_req || (!sdr_busy && !d_sdram);
  wire sdr_d_start = d_sdram && !sdr_busy;
  wire sdr_i_start = i_sdram_req && !sdr_busy && !d_sdram;
  wire sdr_i_more  = sdr_busy && sdr_who && !sdr_second && sdr_ack && in_sdram(sdr_iaddr + 32'd4);
  wire [31:0] sdr_addr = sdr_d_start ? d_addr : sdr_i_start ? i_addr : sdr_iaddr + 32'd4;
  mycpu_sdram #(.SDRAM_HZ(SDRAM_HZ)) sdram (
    .clk(clk), .rst(rst),
    .req(sdr_d_start || sdr_i_start || sdr_i_more), .waddr(sdr_addr[22:2]),
    .wstrb(sdr_d_start ? d_wstrb : 4'd0), .wdata(d_wdata),
    .ack(sdr_ack), .rdata(sdram_q), .ready_init(),
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n), .sdram_a(sdram_a), .sdram_ba(sdram_ba),
    .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq)
  );
  wire sdr_i_done = sdr_busy && sdr_who && sdr_ack && (sdr_second || !in_sdram(sdr_iaddr + 32'd4));
  always @(posedge clk) begin
    if (rst) begin
      sdr_busy <= 1'b0; sdr_who <= 1'b0; sdr_second <= 1'b0; sdr_iaddr <= 32'd0; sdr_w0 <= 32'd0;
    end else begin
      if (sdr_d_start) begin sdr_busy <= 1'b1; sdr_who <= 1'b0; end
      else if (sdr_i_start) begin sdr_busy <= 1'b1; sdr_who <= 1'b1; sdr_second <= 1'b0; sdr_iaddr <= i_addr; end
      else if (sdr_ack && !sdr_who) sdr_busy <= 1'b0;
      else if (sdr_i_more) begin sdr_second <= 1'b1; sdr_w0 <= sdram_q; end
      else if (sdr_i_done) sdr_busy <= 1'b0;
      if (sdr_i_done && !sdr_second) sdr_w0 <= sdram_q;
    end
  end

  // ---- 入出力（仮決め。lib/isa.js の IO と同じ） ----
  localparam [14:0] IO_UART_TX = 15'h00, IO_UART_STATUS = 15'h04, IO_UART_RX = 15'h08,
                    IO_TIMER_COUNT = 15'h10, IO_TIMER_CMP = 15'h14, IO_TIMER_CTRL = 15'h18,
                    IO_LED = 15'h20,
                    IO_SD_DATA = 15'h30, IO_SD_CTRL = 15'h34, IO_SD_STATUS = 15'h38;
  wire [14:0] io_off = {d_addr[14:2], 2'b00};
  // 書き込み：レジスタの先頭バイトを含むときだけ効く。書かないバイトは 0
  wire [31:0] wmask = {{8{d_wstrb[3]}}, {8{d_wstrb[2]}}, {8{d_wstrb[1]}}, {8{d_wstrb[0]}}};
  wire [31:0] io_w = d_wdata & wmask;
  wire io_we = d_go && sel_io && d_wstrb[0];

  wire       tx_ready, rx_valid;
  wire [7:0] rx_data;
  mycpu_uart #(.DIV(CLK_HZ / BAUD)) uart (
    .clk(clk), .rst(rst),
    .tx_we(io_we && io_off == IO_UART_TX), .tx_data(io_w[7:0]), .tx_ready(tx_ready), .txd(uart_txd),
    .rx_re(d_go && sel_io && !wr && io_off == IO_UART_RX), .rx_data(rx_data), .rx_valid(rx_valid),
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

  // SPI：SD_DATA に書くと 8bit を送りながら受け取る（MSB から）。SD_CTRL の bit0 = CS、bit15〜8 = 分周
  //   SCK の半周期 = (分周 + 1) クロック。SCK が上がるときに MISO を取り込み、下がるときに MOSI を変える
  reg [15:0] spi_ctrl;
  reg [7:0]  spi_sh, spi_rx;
  reg [7:0]  spi_cnt;
  reg [3:0]  spi_bits;
  reg        spi_busy, spi_sck;
  assign sd_sclk = spi_sck;
  assign sd_mosi = spi_sh[7];
  assign sd_cs_n = !spi_ctrl[0];
  always @(posedge clk) begin
    if (rst) begin
      spi_ctrl <= 16'd0; spi_busy <= 1'b0; spi_sck <= 1'b0; spi_sh <= 8'hFF; spi_rx <= 8'hFF;
      spi_cnt <= 8'd0; spi_bits <= 4'd0;
    end else begin
      if (io_we && io_off == IO_SD_CTRL) spi_ctrl <= {io_w[15:8], 7'd0, io_w[0]};
      if (!spi_busy) begin
        if (io_we && io_off == IO_SD_DATA) begin
          spi_sh <= io_w[7:0];
          spi_busy <= 1'b1;
          spi_cnt <= 8'd0;
          spi_bits <= 4'd0;
        end
      end else if (spi_cnt != spi_ctrl[15:8]) spi_cnt <= spi_cnt + 8'd1;
      else begin
        spi_cnt <= 8'd0;
        spi_sck <= !spi_sck;
        if (!spi_sck) spi_rx <= {spi_rx[6:0], sd_miso};          // 上がる
        else begin                                                 // 下がる
          spi_sh <= {spi_sh[6:0], 1'b1};
          spi_bits <= spi_bits + 4'd1;
          if (spi_bits == 4'd7) spi_busy <= 1'b0;
        end
      end
    end
  end

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
      IO_SD_DATA:     io_q <= {24'd0, spi_rx};
      IO_SD_CTRL:     io_q <= {16'd0, spi_ctrl};
      IO_SD_STATUS:   io_q <= {31'd0, spi_busy};
      default:        io_q <= 32'd0;
    endcase
  end

  // ---- 応答（SDRAM は返事が来たとき、ほかは次のクロック） ----
  reg [2:0] d_which;   // 0 = ROM、1 = 入出力、2 = VRAM、3 = RAM、4 = SDRAM
  reg       d_odd_q;
  reg [1:0] i_which;   // 0 = ROM、1 = RAM、2 = SDRAM、3 = なし
  reg       i_odd_q;
  reg       i_fast;    // 次のクロックで返す（ROM・RAM・つながっていない番地）
  always @(posedge clk) begin
    if (rst) begin
      d_rvalid <= 1'b0; i_rvalid <= 1'b0; d_which <= 3'd0; d_odd_q <= 1'b0;
      i_which <= 2'd0; i_odd_q <= 1'b0; i_err <= 2'b00;
    end else begin
      // データの口
      d_rvalid <= (d_go && !sel_sdram) || (sdr_ack && !sdr_who);
      if (d_go) begin
        d_which <= sel_io ? 3'd1 : sel_vram ? 3'd2 : sel_ram ? 3'd3 : sel_sdram ? 3'd4 : 3'd0;
        d_odd_q <= d_odd;
      end
      // 命令の口：2 つ目の 4 バイトが同じ場所になければ、そこは読めない印
      i_rvalid <= (i_go && !i_sdram) || sdr_i_done;
      if (i_go && !i_sdram) begin
        i_which <= i_rom ? 2'd0 : i_ram ? 2'd1 : 2'd3;
        i_odd_q <= i_addr[2];
        i_err <= {!((i_rom && in_rom(i_addr1)) || (i_ram && in_ram(i_addr1))), !(i_rom || i_ram)};
      end else if (sdr_i_done) begin
        i_which <= 2'd2;
        i_err <= {!sdr_second, 1'b0};
      end
    end
  end
  wire [31:0] rom_d = d_odd_q ? rom_do : rom_de;
  wire [31:0] ram_d = d_odd_q ? ram_do : ram_de;
  assign d_rdata = d_which == 3'd0 ? rom_d : d_which == 3'd1 ? io_q : d_which == 3'd2 ? vram_q :
                   d_which == 3'd3 ? ram_d : sdram_q;
  wire [63:0] rom_i = i_odd_q ? {rom_ie, rom_io} : {rom_io, rom_ie};
  wire [63:0] ram_i = i_odd_q ? {ram_ie, ram_io} : {ram_io, ram_ie};
  assign i_rdata = i_which == 2'd0 ? rom_i : i_which == 2'd1 ? ram_i : i_which == 2'd2 ? {sdram_q, sdr_w0} : 64'd0;
endmodule

// 2 ポートの RAM（同じクロック。A は読むだけ、B は読み書き。BSRAM の 2 ポートになる書き方）
module mycpu_tdpram #(parameter integer AW = 13, parameter integer DEPTH = 1 << AW) (
  input  wire          clk,
  input  wire [AW-1:0] addra,
  output reg  [7:0]    douta,
  input  wire          web,
  input  wire [AW-1:0] addrb,
  input  wire [7:0]    dinb,
  output reg  [7:0]    doutb
);
  reg [7:0] mem [0:DEPTH - 1];
`ifdef MYCPU_SIM
  integer i;   // シミュレーションでは 0 にしておく（実機の BSRAM も 0 から始まる）
  initial for (i = 0; i < DEPTH; i = i + 1) mem[i] = 8'd0;
`endif
  always @(posedge clk) douta <= mem[addra];
  always @(posedge clk) begin
    if (web) mem[addrb] <= dinb;
    doutb <= mem[addrb];
  end
endmodule

// ROM（読み出し口が 2 つ。中身は HEX）
module mycpu_rom2 #(parameter HEX = "", parameter integer AW = 11) (
  input  wire          clk,
  input  wire [AW-1:0] addra,
  output reg  [31:0]   douta,
  input  wire [AW-1:0] addrb,
  output reg  [31:0]   doutb
);
  reg [31:0] mem [0:(1 << AW) - 1];
  initial $readmemh(HEX, mem);
  always @(posedge clk) begin
    douta <= mem[addra];
    doutb <= mem[addrb];
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
