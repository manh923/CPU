; MANDEL.EXE — マンデルブロ集合を色付きの文字で描く（固定小数点、小数部 12bit）
; 色は BIOS の変数（BIOS Data Area の ATTR）を直接書き換えて変える。
BIOS_PUTC   = 0x10
ATTR        = 0x00027008                ; BIOS の今の色
W           = 120                       ; 横の文字数
H           = 36                        ; 行数
X0          = -9011                     ; -2.2 × 4096
DX          = 109                       ; 3.2 / W × 4096
Y0          = -4915                     ; -1.2 × 4096
DY          = 273                       ; 2.4 / H × 4096
MAXI        = 32                        ; これだけ回して発散しなければ集合の中

        .org 0x23000
start:
        ADDI32 sp, sp, -32
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        STORE32_32 r28, sp, 20
        STORE32_32 r29, sp, 24
        STORE32_32 r30, sp, 28
        ADDI32 r24, r0, 0               ; 行
.row:   MULI32 r26, r24, DY             ; ci
        ADDI32 r26, r26, Y0
        ADDI32 r25, r0, 0               ; 桁
.col:   MULI32 r27, r25, DX             ; cr
        ADDI32 r27, r27, X0
        ADDI32 r28, r0, 0               ; zr
        ADDI32 r29, r0, 0               ; zi
        ADDI32 r30, r0, 0               ; 回数
.it:    MULR32 r16, r28, r28            ; zr²
        SARI32 r16, r16, 12
        MULR32 r17, r29, r29            ; zi²
        SARI32 r17, r17, 12
        ADDR32 r18, r16, r17
        CMPGEI32 p1, r18, 16385         ; |z|² > 4 なら発散
        BR32 p1, .esc
        MULR32 r19, r28, r29            ; zi = 2·zr·zi + ci
        SARI32 r19, r19, 11
        ADDR32 r29, r19, r26
        SUBR32 r28, r16, r17            ; zr = zr² − zi² + cr
        ADDR32 r28, r28, r27
        ADDI32 r30, r30, 1
        CMPLTI32 p1, r30, MAXI
        BR32 p1, .it
        ADDI32 r16, r0, ' '             ; 集合の中は黒
        ADDI32 r18, r0, 0x07
        JMP32 .put
.esc:   ANDI32 r17, r30, 15
        LOAD8U_32 r16, r17, ramp
        LOAD8U_32 r18, r17, colors
.put:   STORE32_32 r18, r0, ATTR
        CALL32 BIOS_PUTC
        ADDI32 r25, r25, 1
        CMPLTI32 p1, r25, W
        BR32 p1, .col
        ADDI32 r16, r0, 0x07
        STORE32_32 r16, r0, ATTR
        ADDI32 r16, r0, 10
        CALL32 BIOS_PUTC
        ADDI32 r24, r24, 1
        CMPLTI32 p1, r24, H
        BR32 p1, .row
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        LOAD32_32 r28, sp, 20
        LOAD32_32 r29, sp, 24
        LOAD32_32 r30, sp, 28
        ADDI32 sp, sp, 32
        RET32

ramp:   .ascii ".,:;-=+*#%@@%#*+"
colors: .byte 0x01, 0x09, 0x03, 0x0B, 0x02, 0x0A, 0x0E, 0x06
        .byte 0x0C, 0x04, 0x05, 0x0D, 0x0F, 0x07, 0x08, 0x09
