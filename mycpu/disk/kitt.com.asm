; KITT.COM — 基板の LED（6 個）を左右に流す。キーを押すと止まる
; .COM なのでヘッダはなく、0x23000 に置かれてそのまま実行される。
BIOS_PUTC   = 0x10
BIOS_PUTS   = 0x18
UART_STATUS = 0x00010004
UART_RX     = 0x00010008
TIMER_COUNT = 0x00010010
LED         = 0x00010020
STEP_US     = 70000

        .org 0x23000
start:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDI32 r16, r0, s_msg
        CALL32 BIOS_PUTS
        ADDI32 r24, r0, 1               ; 光っている LED
        ADDI32 r25, r0, 1               ; 1 = 左へ、0 = 右へ
.loop:  STORE32_32 r24, r0, LED
        ADDI32 r16, r0, 13              ; 画面にも [*.....] の形で出す
        CALL32 BIOS_PUTC
        ADDI32 r16, r0, '['
        CALL32 BIOS_PUTC
        ADDI32 r26, r0, 5
.bar:   SHRR32 r16, r24, r26
        ANDI32 r16, r16, 1
        CMPNEI32 p1, r16, 0
        ADDI32 r16, r0, '*'
        ADDI32 r17, r0, '.'
        SEL32 r16, r16, r17, p1
        CALL32 BIOS_PUTC
        ADDI32 r26, r26, -1
        CMPGEI32 p1, r26, 0
        BR32 p1, .bar
        ADDI32 r16, r0, ']'
        CALL32 BIOS_PUTC
        LOAD32_32 r26, r0, TIMER_COUNT  ; 少し待つ。キーが来たら終わり
.wait:  LOAD32_32 r16, r0, UART_STATUS
        ANDI32 r16, r16, 2
        CMPNEI32 p1, r16, 0
        BR32 p1, .key
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r26
        CMPLTUI32 p1, r16, STEP_US
        BR32 p1, .wait
        CMPEQI32 p1, r25, 0
        BR32 p1, .right
        SHLI32 r24, r24, 1
        CMPEQI32 p1, r24, 0x20
        SEL32 r25, r0, r25, p1
        JMP32 .loop
.right: SHRI32 r24, r24, 1
        CMPEQI32 p1, r24, 1
        ADDI32 r16, r0, 1
        SEL32 r25, r16, r25, p1
        JMP32 .loop
.key:   LOAD32_32 r16, r0, UART_RX      ; 押したキーは捨てる
        STORE32_32 r0, r0, LED
        ADDI32 r16, r0, 10
        CALL32 BIOS_PUTC
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

s_msg:  .asciz "LED chaser - press any key to stop.\n"
