; colors.asm — 画面の確認用：256 文字の表と 16 色 × 16 色の表を描いて止まる
; Verilog の表示回路の出力と、シミュレータの絵を比べるのにも使う。
VRAM        = 0x00018000
COLS        = 160

start:
        ; 1 行目に見出し
        ADDI32 r16, r0, title
        ADDI32 r17, r0, VRAM + 2 * 2
.t:     LOAD8U_32 r18, r16, 0
        CMPEQI32 p1, r18, 0
        BR32 p1, .chars
        ORI32 r18, r18, 0x0F00
        STORE16_32 r18, r17, 0
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 2
        JMP32 .t

        ; 文字の表：3 行目から 8 行 × 32 文字（1 文字おき）
.chars: ADDI32 r16, r0, 0               ; 文字コード
.c:     ANDI32 r17, r16, 31             ; 桁 = (code % 32) * 2 + 2
        SHLI32 r17, r17, 1
        ADDI32 r17, r17, 2
        SHRI32 r18, r16, 5              ; 行 = code / 32 + 2
        ADDI32 r18, r18, 2
        MULI32 r18, r18, COLS
        ADDR32 r18, r18, r17
        SHLI32 r18, r18, 1
        ORI32 r19, r16, 0x0700
        STORE16_32 r19, r18, VRAM
        ADDI32 r16, r16, 1
        CMPLTUI32 p1, r16, 256
        BR32 p1, .c

        ; 色の表：12 行目から、背景 16 色 × 文字色 16 色。各升目に "Ab"
        ADDI32 r16, r0, 0               ; 色バイト
.k:     ANDI32 r17, r16, 15             ; 桁 = 文字色 * 4 + 2
        SHLI32 r17, r17, 2
        ADDI32 r17, r17, 2
        SHRI32 r18, r16, 4              ; 行 = 背景色 + 12
        ADDI32 r18, r18, 12
        MULI32 r18, r18, COLS
        ADDR32 r18, r18, r17
        SHLI32 r18, r18, 1
        SHLI32 r19, r16, 8
        ORI32 r20, r19, 'A'
        STORE16_32 r20, r18, VRAM
        ORI32 r20, r19, 'b'
        STORE16_32 r20, r18, VRAM + 2
        ORI32 r20, r19, ' '
        STORE16_32 r20, r18, VRAM + 4
        STORE16_32 r20, r18, VRAM + 6
        ADDI32 r16, r16, 1
        CMPLTUI32 p1, r16, 256
        BR32 p1, .k

        ; 右下の隅にも 1 文字（端まで描けているかの確認）
        ADDI32 r16, r0, 0x4F00 | '#'
        STORE16_32 r16, r0, VRAM + (45 * COLS - 1) * 2
        HLT

title:  .asciz "MyCPU text mode 160x45 - font & palette test"
