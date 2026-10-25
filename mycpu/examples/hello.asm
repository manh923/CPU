; hello.asm — UART と画面（テキスト VRAM）に文字を出す
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
VRAM        = 0x00018000
COLS        = 160

start:
        ADDI32 sp, r0, 0x00028000       ; スタックは内蔵 RAM の末尾（4.4）
        ADDI32 r16, r0, msg
        CALL32 puts

        ; 画面の 2 行目 3 文字目から、青地に黄色で書く
        ADDI32 r16, r0, msg
        ADDI32 r17, r0, VRAM + (1 * COLS + 2) * 2
.loop:  LOAD8U_32 r18, r16, 0
        CMPEQI32 p1, r18, 10            ; 改行で終わり
        BR32 p1, .done
        ORI32 r18, r18, 0x1E00          ; 上位バイトが色：背景 1（青）・文字 14（黄）
        STORE16_32 r18, r17, 0
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 2
        JMP32 .loop
.done:  HLT

; puts: r16 の文字列（0 終わり）を UART に出す。r16〜r18 を壊す
puts:
        ADDR32 r18, lr, r0              ; LR を退避（putc を呼ぶため）
.next:  LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
        CALL32 putc
        ADDI32 r16, r16, 1
        JMP32 .next
.end:   JMPR32 r18

; putc: r17 の 1 文字を UART に出す（\n の前に \r を足す）
putc:
        CMPEQI32 p2, r17, 10
        BR32 p2, .crlf
.out:   LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1              ; bit0 = 送信できる
        CMPEQI32 p2, r19, 0
        BR32 p2, .out
        STORE32_32 r17, r0, UART_TX
        RET32
.crlf:  ADDI32 r17, r0, 13
        ADDR32 r20, lr, r0
        CALL32 .out
        ADDR32 lr, r20, r0
        ADDI32 r17, r0, 10
        JMP32 .out

msg:    .asciz "Hello, MyCPU!\n"
