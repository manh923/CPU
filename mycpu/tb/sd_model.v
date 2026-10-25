// SD カード（SPI モード 0）のモデル。テストベンチ用。lib/sdcard.js と同じ動きにしてある。
//   CMD0・CMD8・CMD55＋ACMD41（2 回目で初期化完了）・CMD58（SDHC）・CMD16・CMD17（1 セクタ読み出し）
//   ディスクの中身は DISK_HEX（$readmemh、1 行 1 バイト、@番地 で飛ばしてよい）。DISK_HEX が空なら「カードなし」
module sd_model #(
  parameter DISK_HEX = "",
  parameter integer SECTORS = 8192
) (
  input  wire sclk,
  input  wire mosi,
  input  wire cs_n,
  output wire miso
);
  localparam PRESENT = DISK_HEX != "";
  reg [7:0] disk [0:SECTORS * 512 - 1];
  integer i;
  initial begin
    for (i = 0; i < SECTORS * 512; i = i + 1) disk[i] = 8'h00;
    if (PRESENT) $readmemh(DISK_HEX, disk);
  end

  // 応答の待ち行列
  reg [7:0] q [0:1023];
  integer qh = 0, qt = 0;
  task push(input [7:0] b);
    begin q[qt] = b; qt = (qt + 1) % 1024; end
  endtask

  reg idle = 1'b1, app = 1'b0;
  integer acmd41 = 0;
  reg [7:0] cmd [0:5];
  integer cmdn = 0;

  task command(input [5:0] c, input [31:0] arg);
    reg was_app;
    reg [7:0] r1;
    integer k;
    begin
      was_app = app;
      app = 1'b0;
      r1 = idle ? 8'h01 : 8'h00;
      push(8'hFF);                                // 応答の前に 1 バイト待たせる
      if (was_app && c == 6'd41) begin
        acmd41 = acmd41 + 1;
        if (acmd41 >= 2) idle = 1'b0;
        push(idle ? 8'h01 : 8'h00);
      end else case (c)
        6'd0: begin idle = 1'b1; acmd41 = 0; push(8'h01); end
        6'd8: begin push(r1); push(8'h00); push(8'h00); push({4'h0, arg[11:8]}); push(arg[7:0]); end
        6'd55: begin app = 1'b1; push(r1); end
        6'd58: begin push(r1); push(8'hC0); push(8'hFF); push(8'h80); push(8'h00); end
        6'd16: push(r1);
        6'd17: begin
          if (idle) push(8'h05);
          else if (arg >= SECTORS) push(8'h40);
          else begin
            push(8'h00); push(8'hFF); push(8'hFF); push(8'hFE);
            for (k = 0; k < 512; k = k + 1) push(disk[arg * 512 + k]);
            push(8'hFF); push(8'hFF);
          end
        end
        default: push(r1 | 8'h04);
      endcase
    end
  endtask

  task receive(input [7:0] b);
    begin
      if (cmdn != 0 || b[7:6] == 2'b01) begin
        cmd[cmdn] = b;
        cmdn = cmdn + 1;
        if (cmdn == 6) begin
          cmdn = 0;
          command(cmd[0][5:0], {cmd[1], cmd[2], cmd[3], cmd[4]});
        end
      end
    end
  endtask

  // ビット単位：SCK が上がるときに MOSI を読み、下がるときに MISO を変える
  reg [7:0] rx = 8'hFF, out_sr = 8'hFF;
  integer bitc = 0;
  assign miso = (cs_n || !PRESENT) ? 1'b1 : out_sr[7];

  always @(posedge cs_n) begin
    qh = 0; qt = 0; cmdn = 0; bitc = 0; out_sr = 8'hFF;
  end
  always @(posedge sclk) if (!cs_n && PRESENT) begin
    rx = {rx[6:0], mosi};
    bitc = bitc + 1;
    if (bitc == 8) begin
      bitc = 0;
      receive(rx);
      if (qh != qt) begin out_sr = q[qh]; qh = (qh + 1) % 1024; end
      else out_sr = 8'hFF;
    end
  end
  always @(negedge sclk) if (!cs_n && PRESENT && bitc != 0) out_sr = {out_sr[6:0], 1'b1};
endmodule
