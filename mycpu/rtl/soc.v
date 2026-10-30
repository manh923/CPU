// CPU とメモリ・入出力をつないだもの（4.1 のメモリマップ）
//   0x0000_0000 ROM 16KB（中身は ROM_EVEN_HEX・ROM_ODD_HEX。偶数番目と奇数番目の 4 バイトに分けたもの）
//   0x0001_0000 入出力（UART・タイマー・LED。番地は README）
//   0x0001_8000 テキスト VRAM 16KB（表示回路側にも読み出し口がある）
//   0x0002_0000 内蔵 RAM 32KB（命令もデータも）
//   0x0002_A000 内蔵 RAM 8KB（データだけ。BIOS の変数・スタック。0x0002_8000〜0x0002_9FFF はない）
//   0x0100_0000 SDRAM 8MB（rtl/sdram.v。命令キャッシュとデータキャッシュ（どちらも 8KB）を通す）
//   0x0200_0000 同じ SDRAM を、データキャッシュを通さずに 1 語ずつ読み書きする（グラフィックのフレームバッファ用）
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
  output wire [31:0] vdata,
  // グラフィック（7.3。どれも vclk 側）：行バッファ（4 バイト単位の番地、1 クロック後に gdata）・
  // パレット（1 クロック後に pdata）・モード（clk 側のレジスタ。表示回路で揃える）、
  // 表示回路からの「この行を読んで」（greq_t が変わるたびに greq_y の行を、行の番号の偶奇の行バッファへ）
  input  wire [7:0]  gaddr,
  output reg  [31:0] gdata,
  input  wire [7:0]  paddr,
  output reg  [23:0] pdata,
  output reg         gmode,
  input  wire        greq_t,
  input  wire [7:0]  greq_y
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
  function in_rama(input [31:0] a);  in_rama  = a[31:15] == 17'h4;                        endfunction // 0x0002_0000〜0x0002_7FFF
  function in_ramb(input [31:0] a);  in_ramb  = a[31:13] == 19'h15;                       endfunction // 0x0002_A000〜0x0002_BFFF（データだけ）
  function in_ram(input [31:0] a);   in_ram   = in_rama(a) || in_ramb(a);                 endfunction
  function in_sdram(input [31:0] a); in_sdram = a[31:23] == 9'h2;                         endfunction // 0x0100_0000〜0x017F_FFFF
  function in_uc(input [31:0] a);    in_uc    = a[31:23] == 9'h4;                         endfunction // 0x0200_0000〜0x027F_FFFF

  // データの口
  wire sel_rom = in_rom(d_addr), sel_io = in_io(d_addr), sel_vram = in_vram(d_addr);
  wire sel_ram = in_ram(d_addr), sel_sdram = in_sdram(d_addr), sel_uc = in_uc(d_addr);
  wire wr = d_wstrb != 4'd0;
  assign d_err = d_req && (!(sel_rom || sel_io || sel_vram || sel_ram || sel_sdram || sel_uc) || (sel_rom && wr));
  wire d_go = d_req && d_gnt && !d_err;         // このクロックで受け付けた
  wire d_odd = d_addr[2];                        // 奇数番目の 4 バイト

  // 命令の口（i_addr とその次の 4 バイト）
  wire [31:0] i_addr1 = i_addr + 32'd4;
  wire i_rom = in_rom(i_addr), i_ram = in_rama(i_addr), i_sdram = in_sdram(i_addr);   // 命令は RAM の前の 32KB だけ
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

  // ---- 内蔵 RAM の前の 32KB（偶数・奇数 × 4 バイト。どれも 2 ポート：A は命令の口が読むだけ、B はデータの口） ----
  //   命令の口：奇数側は i_addr の 8 バイト、偶数側は i_addr+4 の 8 バイト（i_addr が偶数番目なら同じところ）
  //   後ろの 8KB（データだけ）は 4 バイト × 2048 の 1 ポート
  wire d_ramb = in_ramb(d_addr);
  wire [31:0] ram_ie, ram_io, ram_de, ram_do, ramb_q, vram_q;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : lane
      mycpu_tdpram #(.AW(12)) ram_e (
        .clk(clk), .addra(i_addr1[14:3]), .douta(ram_ie[8*g +: 8]),
        .web(d_go && sel_ram && !d_ramb && !d_odd && d_wstrb[g]), .addrb(d_addr[14:3]), .dinb(d_wdata[8*g +: 8]),
        .doutb(ram_de[8*g +: 8])
      );
      mycpu_tdpram #(.AW(12)) ram_o (
        .clk(clk), .addra(i_addr[14:3]), .douta(ram_io[8*g +: 8]),
        .web(d_go && sel_ram && !d_ramb && d_odd && d_wstrb[g]), .addrb(d_addr[14:3]), .dinb(d_wdata[8*g +: 8]),
        .doutb(ram_do[8*g +: 8])
      );
      mycpu_spram #(.AW(11)) ram_b (
        .clk(clk), .we(d_go && d_ramb && d_wstrb[g]), .addr(d_addr[12:2]), .din(d_wdata[8*g +: 8]),
        .dout(ramb_q[8*g +: 8])
      );
      mycpu_dpram #(.AW(12)) vram (
        .clka(clk), .wea(d_go && sel_vram && d_wstrb[g]), .addra(d_addr[13:2]),
        .dina(d_wdata[8*g +: 8]), .douta(vram_q[8*g +: 8]),
        .clkb(vclk), .addrb(vaddr), .doutb(vdata[8*g +: 8])
      );
    end
  endgenerate

  // ---- 命令キャッシュ（SDRAM の命令だけ。8KB、ダイレクトマップ、1 ライン 64 バイト × 128） ----
  //   番地 [22:13] がタグ、[12:6] がライン、[5:2] がライン内の語。データは偶数・奇数番目の 4 バイトに分けて
  //   8 バイトを 1 クロックで読む（ラインをまたぐ命令は、両方のラインがあれば当たり）。
  //   外れたら SDRAM からライン 1 本（16 語）をバーストで読む。そのラインがデータキャッシュで書き換えられて
  //   いれば、先に SDRAM へ書き戻させる。データの口で SDRAM の番地に書いたら、そのラインを無効にする
  //   （読み込んだプログラム・自分を書き換えるコードでも正しく動く）
  reg  [9:0]  ic_tag [0:127];
  reg  [127:0] ic_valid;
  // あるかどうか（関数にすると、タグが変わってもシミュレーションで計算し直されないので、式で書く）
  wire i_sdram1 = in_sdram(i_addr1);
  wire ic_hit0 = ic_valid[i_addr[12:6]] && ic_tag[i_addr[12:6]] == i_addr[22:13];
  wire ic_hit1 = !i_sdram1 || (ic_valid[i_addr1[12:6]] && ic_tag[i_addr1[12:6]] == i_addr1[22:13]);  // SDRAM の外なら読めない印だけ

  localparam [1:0] IC_IDLE = 2'd0, IC_FILL = 2'd1, IC_REPLY = 2'd2;
  reg [1:0]  ic_state;
  reg [31:0] ic_addr;            // 外れた要求の番地
  reg [31:0] ic_line;            // 読んでいるラインの先頭
  reg [3:0]  ic_n;               // 届いた語の数
  wire [31:0] ic_addr1 = ic_addr + 32'd4;
  wire ic_has0 = ic_valid[ic_addr[12:6]] && ic_tag[ic_addr[12:6]] == ic_addr[22:13];
  wire ic_has1 = ic_valid[ic_addr1[12:6]] && ic_tag[ic_addr1[12:6]] == ic_addr1[22:13];
  wire ic_hasd = ic_valid[d_addr[12:6]] && ic_tag[d_addr[12:6]] == d_addr[22:13];

  // データ（偶数・奇数 × 1024 語）。A は命令の口が読む、B はライン読み込みで書く
  wire [10:0] ic_rw  = (ic_state == IC_REPLY ? ic_addr[12:2] : i_addr[12:2]);
  wire [10:0] ic_rw1 = ic_rw + 11'd1;
  wire [31:0] ic_qe, ic_qo;
  wire        sdr_bvalid;
  wire [31:0] sdram_q;
  reg  [1:0]  sdr_who;           // SDRAM を使っているのは
  localparam [1:0] W_DC = 2'd0, W_IC = 2'd1, W_UC = 2'd2, W_VID = 2'd3;   // データキャッシュ・命令キャッシュ・キャッシュなし・表示
  wire [10:0] ic_ww = {ic_line[12:6], ic_n};
  wire        ic_wr = sdr_bvalid && sdr_who == W_IC && ic_state == IC_FILL;
  mycpu_icram ic_e (.clk(clk), .addra(ic_rw1[10:1]), .douta(ic_qe),
                    .web(ic_wr && !ic_n[0]), .addrb(ic_ww[10:1]), .dinb(sdram_q));
  mycpu_icram ic_o (.clk(clk), .addra(ic_rw[10:1]), .douta(ic_qo),
                    .web(ic_wr && ic_n[0]), .addrb(ic_ww[10:1]), .dinb(sdram_q));

  // ---- データキャッシュ（SDRAM のデータ。8KB、ダイレクトマップ、1 ライン 64 バイト × 128、ライトバック） ----
  //   番地の分け方は命令キャッシュと同じ。当たれば内蔵 RAM と同じく次のクロックに返す（書き込みも）。
  //   外れたら d_gnt を 0 にしたまま：今のラインが書き換えられていれば（汚れ）16 語を wbuf に写して SDRAM に
  //   バーストで書き戻し、それから新しいラインを 16 語バーストで読む。読み終えると、待っていた要求が当たる。
  //   書き込みも、ラインを読んでから書く（ライトアロケート）
  reg  [9:0]   dc_tag [0:127];
  reg  [127:0] dc_valid, dc_dirty;
  wire [6:0]   d_idx = d_addr[12:6];
  wire dc_hit = dc_valid[d_idx] && dc_tag[d_idx] == d_addr[22:13];
  localparam [2:0] DC_IDLE = 3'd0, DC_COPY = 3'd1, DC_WBW = 3'd2, DC_WB = 3'd3, DC_FILLW = 3'd4, DC_FILL = 3'd5;
  reg [2:0]  dc_state;
  reg [16:0] dc_vline;           // 書き戻すライン（番地の [22:6]）
  reg [16:0] dc_fline;           // 読み込むライン
  reg        dc_fill_after;      // 書き戻した後に読み込む（0 = 命令キャッシュのための書き戻しだけ）
  reg [4:0]  dc_cnt;             // wbuf に写した語の数（読み出しは 1 クロック遅れて届く）
  reg [3:0]  dc_n;               // ライン読み込みで届いた語の数
  reg [31:0] wbuf [0:15];        // 書き戻す 16 語
  wire [3:0] sdr_bidx;
  // データ（4 バイト × 2048、1 ポート）：ふだんはデータの口、外れの処理中は写す・読み込む場所
  wire [10:0] dc_ra = dc_state == DC_COPY ? {dc_vline[6:0], dc_cnt[3:0]} :
                      dc_state == DC_FILL ? {dc_fline[6:0], dc_n} : d_addr[12:2];
  wire        dc_fwr = dc_state == DC_FILL && sdr_bvalid && sdr_who == W_DC;
  wire [31:0] dc_q;
  generate
    for (g = 0; g < 4; g = g + 1) begin : dlane
      mycpu_spram #(.AW(11)) dc_ram (
        .clk(clk), .we(dc_fwr || (d_go && sel_sdram && d_wstrb[g])), .addr(dc_ra),
        .din(dc_fwr ? sdram_q[8*g +: 8] : d_wdata[8*g +: 8]), .dout(dc_q[8*g +: 8])
      );
    end
  endgenerate

  // ---- SDRAM：データキャッシュ（書き戻し・ライン読み込み）、キャッシュを通さない読み書き、表示回路の行読み込み、
  //      命令キャッシュのライン読み込みで取り合う（この順で先） ----
  wire        sdr_ack;
  reg         sdr_busy;          // 制御回路が動いている
  wire d_sdram = d_req && sel_sdram && !d_err;
  wire i_sdram_req = i_req && i_sdram;
  wire i_hit = ic_hit0 && ic_hit1;
  // 命令キャッシュが読んでいるラインへの書き込みは、読み終えるまで待つ（読み終えてから無効にする）
  wire ic_filling_d = sdr_busy && sdr_who == W_IC && d_addr[22:6] == ic_line[22:6];
  // キャッシュを通さない読み書き（0x0200_0000〜）：SDRAM が空いていれば 1 語、終わったら返事
  wire d_uc = d_req && sel_uc && !d_err;
  wire uc_go = d_uc && dc_state == DC_IDLE && !sdr_busy;
  assign d_gnt = (!d_sdram || (dc_state == DC_IDLE && dc_hit && !(wr && ic_filling_d))) && (!d_uc || uc_go);
  assign i_gnt = !i_sdram_req || i_hit || ic_state == IC_IDLE;
  wire ic_miss = i_sdram_req && !i_hit && i_gnt;           // 外れを受け付けた
  // 次に読むライン：まず 1 つ目の語のライン、それがあれば 2 つ目の語のライン
  wire [31:0] ic_next_line = ic_has0 ? {ic_addr1[31:6], 6'd0} : {ic_addr[31:6], 6'd0};
  wire ic_more = ic_has0 && (!in_sdram(ic_addr1) || ic_has1);   // もう全部ある
  wire ic_want = ic_state == IC_FILL && !ic_more;
  // そのラインがデータキャッシュで汚れている（先に書き戻す）
  wire [6:0] icn_idx = ic_next_line[12:6];
  wire ic_snoop = dc_valid[icn_idx] && dc_dirty[icn_idx] && dc_tag[icn_idx] == ic_next_line[22:13];
  wire dc_miss  = dc_state == DC_IDLE && d_sdram && !dc_hit;              // データの外れを始める
  wire dc_snoop = dc_state == DC_IDLE && !d_sdram && ic_want && ic_snoop;  // 命令キャッシュのための書き戻しを始める
  wire dc_wb_go   = dc_state == DC_WBW && !sdr_busy;
  wire dc_fill_go = dc_state == DC_FILLW && !sdr_busy;

  // グラフィックの行読み込み：表示回路が頼んだ行（320 バイト = 16 語 × 5）をバーストで読み、行バッファへ。
  // 行バッファの番地は {行の番号の最下位, 語の番号（0〜79）}。グラフィックのときだけ読む
  reg  [2:0]  vq_s;              // 頼みのトグルを clk に揃える（2 段）＋ 変わったかを見る 1 段
  reg  [7:0]  vf_y;              // 読んでいる行
  reg  [2:0]  vf_n;              // 読み終えたバースト（0〜4）
  reg  [3:0]  vf_w;              // バーストの中の語
  reg         vf_pend;
  reg  [16:0] fb_base;           // FB_BASE（SDRAM の中の番地の [22:6]）
  wire [22:0] vf_addr = {fb_base, 6'd0} + {7'd0, vf_y, 8'd0} + {9'd0, vf_y, 6'd0} + {14'd0, vf_n, 6'd0};
  wire vf_go = vf_pend && !sdr_busy && !dc_wb_go && !dc_fill_go && !uc_go;
  reg  [31:0] lbuf [0:255];      // 行バッファ（LUT の RAM。BSRAM は使い切っている）
`ifdef MYCPU_SIM
  integer li;
  initial for (li = 0; li < 256; li = li + 1) lbuf[li] = 32'd0;
`endif
  always @(posedge clk) if (sdr_bvalid && sdr_who == W_VID) lbuf[{vf_y[0], vf_n, vf_w}] <= sdram_q;
  always @(posedge vclk) gdata <= lbuf[gaddr];

  reg  ic_go;                    // このクロックで命令キャッシュのライン読み込みを始める
  always @* ic_go = ic_want && !sdr_busy && dc_state == DC_IDLE && !dc_miss && !ic_snoop && !uc_go && !vf_go;
  mycpu_sdram #(.SDRAM_HZ(SDRAM_HZ)) sdram (
    .clk(clk), .rst(rst),
    .req(dc_wb_go || dc_fill_go || uc_go || vf_go || ic_go),
    .waddr(dc_wb_go ? {dc_vline, 4'd0} : dc_fill_go ? {dc_fline, 4'd0} : uc_go ? d_addr[22:2] :
           vf_go ? vf_addr[22:2] : ic_next_line[22:2]),
    .wstrb(dc_wb_go ? 4'hF : uc_go ? d_wstrb : 4'd0), .wdata(d_wdata), .burst(!uc_go),
    .bwdata(wbuf[sdr_bidx]), .bidx(sdr_bidx),
    .ack(sdr_ack), .bvalid(sdr_bvalid), .rdata(sdram_q), .ready_init(),
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n), .sdram_a(sdram_a), .sdram_ba(sdram_ba),
    .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq)
  );
  always @(posedge clk) begin
    if (rst) begin
      sdr_busy <= 1'b0; sdr_who <= W_DC; ic_state <= IC_IDLE;
      vq_s <= 3'd0; vf_y <= 8'd0; vf_n <= 3'd0; vf_w <= 4'd0; vf_pend <= 1'b0; ic_addr <= 32'd0; ic_line <= 32'd0; ic_n <= 4'd0;
      ic_valid <= 128'd0;
      dc_state <= DC_IDLE; dc_valid <= 128'd0; dc_dirty <= 128'd0; dc_vline <= 17'd0; dc_fline <= 17'd0;
      dc_fill_after <= 1'b0; dc_cnt <= 5'd0; dc_n <= 4'd0;
    end else begin
      if (dc_wb_go || dc_fill_go) begin sdr_busy <= 1'b1; sdr_who <= W_DC; end
      else if (uc_go) begin sdr_busy <= 1'b1; sdr_who <= W_UC; end
      else if (vf_go) begin sdr_busy <= 1'b1; sdr_who <= W_VID; vf_w <= 4'd0; end
      else if (ic_go) begin sdr_busy <= 1'b1; sdr_who <= W_IC; ic_line <= ic_next_line; ic_n <= 4'd0; end
      else if (sdr_ack) sdr_busy <= 1'b0;
      // 表示回路の行読み込み
      vq_s <= {vq_s[1:0], greq_t};
      if (vq_s[2] != vq_s[1] && gmode) begin vf_y <= greq_y; vf_n <= 3'd0; vf_pend <= 1'b1; end
      else if (sdr_who == W_VID && sdr_ack) begin
        if (vf_n == 3'd4) vf_pend <= 1'b0;
        vf_n <= vf_n + 3'd1;
      end
      if (sdr_who == W_VID && sdr_bvalid) vf_w <= vf_w + 4'd1;
      // 命令キャッシュのライン読み込み：届いた語を書き、最後の語でタグを書く
      if (ic_wr) ic_n <= ic_n + 4'd1;
      if (ic_state == IC_FILL && sdr_who == W_IC && sdr_ack) begin
        ic_valid[ic_line[12:6]] <= 1'b1;
        ic_tag[ic_line[12:6]] <= ic_line[22:13];
      end
      case (ic_state)
        IC_IDLE:  if (ic_miss) begin ic_state <= IC_FILL; ic_addr <= i_addr; end
        IC_FILL:  if (ic_more) ic_state <= IC_REPLY;     // 全部そろった：次のクロックで読んで返す
        default:  ic_state <= IC_IDLE;                   // IC_REPLY
      endcase
      // データの口で SDRAM の番地に書いたら、命令キャッシュのそのラインを無効に
      if (d_go && (sel_sdram || sel_uc) && wr && ic_hasd) ic_valid[d_idx] <= 1'b0;

      // データキャッシュ
      if (d_go && sel_sdram && wr) dc_dirty[d_idx] <= 1'b1;
      case (dc_state)
        DC_IDLE:
          if (dc_miss) begin
            dc_fline <= d_addr[22:6]; dc_fill_after <= 1'b1;
            dc_vline <= {dc_tag[d_idx], d_idx}; dc_cnt <= 5'd0;
            dc_state <= dc_valid[d_idx] && dc_dirty[d_idx] ? DC_COPY : DC_FILLW;
          end else if (dc_snoop) begin
            dc_vline <= ic_next_line[22:6]; dc_fill_after <= 1'b0; dc_cnt <= 5'd0;
            dc_state <= DC_COPY;
          end
        DC_COPY: begin                                   // 16 語を wbuf に（読んだ値は 1 クロック後に届く）
          if (dc_cnt != 5'd0) wbuf[dc_cnt[3:0] - 4'd1] <= dc_q;
          dc_cnt <= dc_cnt + 5'd1;
          if (dc_cnt == 5'd16) dc_state <= DC_WBW;
        end
        DC_WBW: if (!sdr_busy) dc_state <= DC_WB;        // dc_wb_go
        DC_WB: if (sdr_ack) begin
          dc_dirty[dc_vline[6:0]] <= 1'b0;
          dc_state <= dc_fill_after ? DC_FILLW : DC_IDLE;
        end
        DC_FILLW: if (!sdr_busy) begin                   // dc_fill_go
          dc_state <= DC_FILL; dc_n <= 4'd0;
          dc_valid[dc_fline[6:0]] <= 1'b0;
        end
        DC_FILL: begin
          if (sdr_bvalid) dc_n <= dc_n + 4'd1;
          if (sdr_ack) begin
            dc_valid[dc_fline[6:0]] <= 1'b1;
            dc_tag[dc_fline[6:0]] <= dc_fline[16:7];
            dc_dirty[dc_fline[6:0]] <= 1'b0;
            dc_state <= DC_IDLE;
          end
        end
        default: dc_state <= DC_IDLE;
      endcase
    end
  end

  // ---- 入出力（仮決め。lib/isa.js の IO と同じ） ----
  localparam [14:0] IO_UART_TX = 15'h00, IO_UART_STATUS = 15'h04, IO_UART_RX = 15'h08,
                    IO_TIMER_COUNT = 15'h10, IO_TIMER_CMP = 15'h14, IO_TIMER_CTRL = 15'h18,
                    IO_LED = 15'h20,
                    IO_SD_DATA = 15'h30, IO_SD_CTRL = 15'h34, IO_SD_STATUS = 15'h38,
                    IO_VIDEO_MODE = 15'h40, IO_FB_BASE = 15'h44, IO_PAL_INDEX = 15'h48, IO_PAL_DATA = 15'h4C;
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

  // グラフィック（7.3）：モード・フレームバッファの番地・パレット（256 色 × 24bit。PAL_DATA に書くと番号が 1 進む。
  // 電源を入れたときは黒、リセットでは変わらない。LUT の RAM で、読むのは表示回路だけ）
  reg  [7:0]  pal_idx;
  reg  [23:0] pal [0:255];
`ifdef MYCPU_SIM
  integer pi;
  initial for (pi = 0; pi < 256; pi = pi + 1) pal[pi] = 24'd0;
`endif
  always @(posedge clk) if (io_we && io_off == IO_PAL_DATA) pal[pal_idx] <= io_w[23:0];
  always @(posedge vclk) pdata <= pal[paddr];

  reg [31:0] io_q;
  always @(posedge clk) begin
    if (rst) begin
      t_count <= 32'd0; t_cmp <= 32'd0; t_en <= 1'b0; t_pre <= 16'd0; led <= 6'd0;
      gmode <= 1'b0; fb_base <= 17'h1F800; pal_idx <= 8'd0;   // FB_BASE は 0x017E0000
    end else begin
      if (t_pre == US_DIV - 1) begin t_pre <= 16'd0; t_count <= t_count + 32'd1; end
      else t_pre <= t_pre + 16'd1;
      if (io_we) case (io_off)
        IO_TIMER_COUNT: begin t_count <= io_w; t_pre <= 16'd0; end
        IO_TIMER_CMP:   t_cmp <= io_w;
        IO_TIMER_CTRL:  t_en <= io_w[0];
        IO_LED:         led <= io_w[5:0];
        IO_VIDEO_MODE:  gmode <= io_w[0];
        IO_FB_BASE:     fb_base <= io_w[22:6];
        IO_PAL_INDEX:   pal_idx <= io_w[7:0];
        IO_PAL_DATA:    pal_idx <= pal_idx + 8'd1;
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
      IO_VIDEO_MODE:  io_q <= {31'd0, gmode};
      IO_FB_BASE:     io_q <= {9'h2, fb_base, 6'd0};
      IO_PAL_INDEX:   io_q <= {24'd0, pal_idx};
      default:        io_q <= 32'd0;          // PAL_DATA は書くだけ
    endcase
  end

  // ---- 応答（SDRAM は返事が来たとき、ほかは次のクロック） ----
  reg [2:0] d_which;   // 0 = ROM、1 = 入出力、2 = VRAM、3 = RAM（前）、4 = SDRAM、5 = RAM（後ろ）、6 = キャッシュなしの SDRAM
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
      // キャッシュを通さない SDRAM は終わったとき、ほかは次のクロックに返す（SDRAM はデータキャッシュに当たったときだけ受け付ける）
      d_rvalid <= (d_go && !sel_uc) || (sdr_ack && sdr_busy && sdr_who == W_UC);
      if (d_go) begin
        d_which <= sel_io ? 3'd1 : sel_vram ? 3'd2 : d_ramb ? 3'd5 : sel_ram ? 3'd3 : sel_sdram ? 3'd4 : sel_uc ? 3'd6 : 3'd0;
        d_odd_q <= d_odd;
      end
      // 命令の口：2 つ目の 4 バイトが同じ場所になければ、そこは読めない印
      i_rvalid <= (i_go && (!i_sdram || i_hit)) || ic_state == IC_REPLY;
      if (i_go && !i_sdram) begin
        i_which <= i_rom ? 2'd0 : i_ram ? 2'd1 : 2'd3;
        i_odd_q <= i_addr[2];
        i_err <= {!((i_rom && in_rom(i_addr1)) || (i_ram && in_rama(i_addr1))), !(i_rom || i_ram)};
      end else if (i_go && i_hit) begin
        i_which <= 2'd2;
        i_odd_q <= i_addr[2];
        i_err <= {!i_sdram1, 1'b0};
      end else if (ic_state == IC_REPLY) begin
        i_which <= 2'd2;
        i_odd_q <= ic_addr[2];
        i_err <= {!in_sdram(ic_addr1), 1'b0};
      end
    end
  end
  wire [31:0] rom_d = d_odd_q ? rom_do : rom_de;
  wire [31:0] ram_d = d_odd_q ? ram_do : ram_de;
  assign d_rdata = d_which == 3'd0 ? rom_d : d_which == 3'd1 ? io_q : d_which == 3'd2 ? vram_q :
                   d_which == 3'd3 ? ram_d : d_which == 3'd5 ? ramb_q : d_which == 3'd6 ? sdram_q : dc_q;
  wire [63:0] rom_i = i_odd_q ? {rom_ie, rom_io} : {rom_io, rom_ie};
  wire [63:0] ram_i = i_odd_q ? {ram_ie, ram_io} : {ram_io, ram_ie};
  wire [63:0] ic_i  = i_odd_q ? {ic_qe, ic_qo} : {ic_qo, ic_qe};
  assign i_rdata = i_which == 2'd0 ? rom_i : i_which == 2'd1 ? ram_i : i_which == 2'd2 ? ic_i : 64'd0;
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

// 1 ポートの RAM（8bit × 2^AW）
module mycpu_spram #(parameter integer AW = 11) (
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

// 命令キャッシュのデータ（32bit × 1024。A は読むだけ、B は書くだけ）
module mycpu_icram (
  input  wire        clk,
  input  wire [9:0]  addra,
  output reg  [31:0] douta,
  input  wire        web,
  input  wire [9:0]  addrb,
  input  wire [31:0] dinb
);
  reg [31:0] mem [0:1023];
  always @(posedge clk) douta <= mem[addra];
  always @(posedge clk) if (web) mem[addrb] <= dinb;
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
