; console.asm — キー入力（UART 受信）を画面と UART にそのまま出すコンソール
;   Enter で改行、Backspace で 1 文字消す、画面の下まで来たら上へずらす、Ctrl-D で HLT
; 受信は WFI で待つ（STATUS の bit8 = UART 受信割り込みのマスクだけ立てて、割り込み許可は 0。
; WFI は割り込みが来たら次の命令へ進むだけなので、ハンドラはいらない）
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
UART_RX     = 0x00010008
VRAM        = 0x00018000
COLS        = 160
ROWS        = 45
ATTR        = 0x07                      ; 黒地に薄い灰色
CURSOR      = 0x0E5F                    ; 黄色の '_'

start:
        ADDI32 sp, r0, 0x00028000
        ; 画面を消す（空白 + ATTR）
        ADDI32 r16, r0, VRAM
        ADDI32 r17, r0, VRAM + COLS * ROWS * 2
        ADDI32 r18, r0, (ATTR << 8) | ' '
.clear: STORE16_32 r18, r16, 0
        ADDI32 r16, r16, 2
        CMPLTUR32 p1, r16, r17
        BR32 p1, .clear

        ; 1 行目に見出し（青地に白）
        ADDI32 r16, r0, banner
        ADDI32 r17, r0, VRAM
.title: LOAD8U_32 r18, r16, 0
        CMPEQI32 p1, r18, 0
        BR32 p1, .titled
        ORI32 r18, r18, 0x1F00
        STORE16_32 r18, r17, 0
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 2
        JMP32 .title
.titled:
        ADDI32 r16, r0, banner
        CALL32 uputs
        ADDI32 r16, r0, 10
        CALL32 uputc

        ADDI32 r24, r0, 0               ; r24 = カーソルの桁
        ADDI32 r25, r0, 2               ; r25 = カーソルの行
        ADDI32 r28, r0, 0               ; r28 = 直前の文字（\r\n を 1 回の改行にする）
        ADDI32 status, r0, 0x0100       ; 割り込み 0（UART 受信）のマスク

main:
        ADDI32 r16, r0, CURSOR
        CALL32 vset
.wait:  LOAD32_32 r17, r0, UART_STATUS
        ANDI32 r17, r17, 2              ; bit1 = 受信あり
        CMPNEI32 p1, r17, 0
        BR32 p1, .got
        WFI
        JMP32 .wait
.got:   LOAD32_32 r16, r0, UART_RX
        ADDR32 r29, r28, r0
        ADDR32 r28, r16, r0
        CMPEQI32 p1, r16, 4             ; Ctrl-D
        BR32 p1, quit
        CMPEQI32 p1, r16, 13
        BR32 p1, .nl
        CMPEQI32 p1, r16, 10
        BR32 p1, .lf
        CMPEQI32 p1, r16, 8
        BR32 p1, .bs
        CMPEQI32 p1, r16, 127
        BR32 p1, .bs
        CMPLTUI32 p1, r16, 32           ; ほかの制御文字は無視
        BR32 p1, main
        ; 普通の文字
        ADDR32 r26, r16, r0
        CALL32 uputc
        ORI32 r16, r26, ATTR << 8
        CALL32 vset
        ADDI32 r24, r24, 1
        CMPLTI32 p1, r24, COLS
        BR32 p1, main
        CALL32 newline
        JMP32 main
.lf:    CMPEQI32 p1, r29, 13            ; \r の直後の \n は無視
        BR32 p1, main
.nl:    ADDI32 r16, r0, 10
        CALL32 uputc
        ADDI32 r16, r0, (ATTR << 8) | ' '
        CALL32 vset
        CALL32 newline
        JMP32 main
.bs:    CMPEQI32 p1, r24, 0
        BR32 p1, main
        ADDI32 r16, r0, bs_seq
        CALL32 uputs
        ADDI32 r16, r0, (ATTR << 8) | ' '
        CALL32 vset
        ADDI32 r24, r24, -1
        JMP32 main

quit:
        ADDI32 r16, r0, (ATTR << 8) | ' '
        CALL32 vset
        ADDI32 r16, r0, bye
        CALL32 uputs
        HLT

; vset: カーソル位置に r16（下位バイト = 文字、上位 = 色）を書く。r17 を壊す
vset:
        MULI32 r17, r25, COLS
        ADDR32 r17, r17, r24
        SHLI32 r17, r17, 1
        STORE16_32 r16, r17, VRAM
        RET32

; newline: 次の行の先頭へ。最後の行なら画面を 1 行上へずらす（見出しの行は残す）。r16〜r18 を壊す
newline:
        ADDI32 r24, r0, 0
        ADDI32 r25, r25, 1
        CMPLTI32 p1, r25, ROWS
        BR32 p1, .done
        ADDI32 r25, r0, ROWS - 1
        ADDI32 r16, r0, VRAM + COLS * 2          ; 2 行目から
        ADDI32 r17, r0, VRAM + (ROWS - 1) * COLS * 2
.copy:  LOAD32_32 r18, r16, COLS * 2
        STORE32_32 r18, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .copy
        ADDI32 r17, r0, VRAM + ROWS * COLS * 2
        ADDI32 r18, r0, (ATTR << 24) | (' ' << 16) | (ATTR << 8) | ' '
.fill:  STORE32_32 r18, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .fill
.done:  RET32

; uputs: r16 の文字列を UART に出す。r16〜r19, r21 を壊す
uputs:
        ADDR32 r21, lr, r0
        ADDR32 r18, r16, r0
.next:  LOAD8U_32 r16, r18, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        CALL32 uputc
        ADDI32 r18, r18, 1
        JMP32 .next
.end:   JMPR32 r21

; uputc: r16 の 1 文字を UART に出す（\n の前に \r）。r16, r19, r20 を壊すことがある
uputc:
        CMPNEI32 p2, r16, 10
        BR32 p2, .one
        ADDI32 r20, r0, 13
        JMP32 .w1
.one:   ADDR32 r20, r16, r0
.w1:    LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p3, r19, 0
        BR32 p3, .w1
        STORE32_32 r20, r0, UART_TX
        BR32 p2, .ret                   ; \n でなければ終わり
        ADDI32 r20, r0, 10
        ADDI32 r16, r0, 0               ; 2 回目は \n をそのまま出す
        CMPNEI32 p2, r16, 10
        JMP32 .w1
.ret:   RET32

banner: .asciz " MyCPU console  -  type something (Enter: newline, Backspace: delete, Ctrl-D: halt) "
bs_seq: .asciz "\b \b"
bye:    .asciz "\n[bye]\n"
