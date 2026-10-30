; gfx.asm — グラフィック画面（7.3）の確認用：パレットを作り、フレームバッファに模様を描き、グラフィックにして止まる
; Verilog の表示回路の出力（SDRAM から行を読んでパレットで色にする）と、シミュレータの絵を比べるのにも使う。
IO_VIDEO_MODE = 0x00010040
IO_FB_BASE    = 0x00010044
IO_PAL_INDEX  = 0x00010048
IO_PAL_DATA   = 0x0001004C
FB            = 0x027E0000              ; フレームバッファ（SDRAM の 0x017E0000）。キャッシュを通さない番地で書く

start:
        ; パレット：番号 i の色 = 赤 (i & 7) × 36、緑 ((i >> 3) & 7) × 36、青 (i >> 6) × 85
        STORE32_32 r0, r0, IO_PAL_INDEX
        ADDI32 r16, r0, 0
.pal:   ANDI32 r17, r16, 7
        MULI32 r17, r17, 36
        SHLI32 r17, r17, 16
        SHRI32 r18, r16, 3
        ANDI32 r18, r18, 7
        MULI32 r18, r18, 36
        SHLI32 r18, r18, 8
        ORR32 r17, r17, r18
        SHRI32 r18, r16, 6
        MULI32 r18, r18, 85
        ORR32 r17, r17, r18
        STORE32_32 r17, r0, IO_PAL_DATA
        ADDI32 r16, r16, 1
        CMPLTI32 p1, r16, 256
        BR32 p1, .pal

        ; 模様：点 (x, y) の色 = (x + 2y) ^ (y / 4)。四隅がわかるように、いちばん外側の点は 255
        ADDI32 r20, r0, FB
        ADDI32 r21, r0, 0               ; y
.row:   SHRI32 r24, r21, 2
        ADDR32 r25, r21, r21
        ADDI32 r22, r0, 0               ; x
.col:   ADDR32 r16, r22, r25
        XORR32 r16, r16, r24
        CMPEQI32 p1, r22, 0
        BR32 p1, .edge
        CMPEQI32 p1, r22, 319
        BR32 p1, .edge
        CMPEQI32 p1, r21, 0
        BR32 p1, .edge
        CMPEQI32 p1, r21, 199
        BR32 p1, .edge
        JMP32 .put
.edge:  ADDI32 r16, r0, 255
.put:   STORE8_32 r16, r20, 0
        ADDI32 r20, r20, 1
        ADDI32 r22, r22, 1
        CMPLTI32 p1, r22, 320
        BR32 p1, .col
        ADDI32 r21, r21, 1
        CMPLTI32 p1, r21, 200
        BR32 p1, .row

        ; 読み戻し（レジスタの比較用）：最後の点、モード・FB_BASE・パレットの番号
        LOAD8U_32 r26, r20, -1
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, IO_VIDEO_MODE
        LOAD32_32 r27, r0, IO_VIDEO_MODE
        LOAD32_32 r28, r0, IO_FB_BASE
        LOAD32_32 r29, r0, IO_PAL_INDEX
        HLT
