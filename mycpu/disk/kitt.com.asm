; KITT.COM — 基板の LED（6 個）を左右に流す。キーを押すと止まる
; .COM なのでヘッダはなく、0x26000 に置かれてそのまま実行される。
; LED とタイマーは入出力の番地を直接読み書きする（ユーザーモードでも入出力には触れる）
SYS_PUTC    = 1
SYS_PUTS    = 2
SYS_GETC    = 3
SYS_KBHIT   = 10
TIMER_COUNT = 0x00010010
LED         = 0x00010020
STEP_US     = 70000

        .org 0x26000
start:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDI32 r16, r0, s_msg
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDI32 r24, r0, 1               ; 光っている LED
        ADDI32 r25, r0, 1               ; 1 = 左へ、0 = 右へ
.loop:  STORE32_32 r24, r0, LED
        ADDI32 r16, r0, 13              ; 画面にも [*.....] の形で出す
        ADDI32 r23, r0, SYS_PUTC
        SYSCALL
        ADDI32 r16, r0, '['
        ADDI32 r23, r0, SYS_PUTC
        SYSCALL
        ADDI32 r26, r0, 5
.bar:   SHRR32 r16, r24, r26
        ANDI32 r16, r16, 1
        CMPNEI32 p1, r16, 0
        ADDI32 r16, r0, '*'
        ADDI32 r17, r0, '.'
        SEL32 r16, r16, r17, p1
        ADDI32 r23, r0, SYS_PUTC
        SYSCALL
        ADDI32 r26, r26, -1
        CMPGEI32 p1, r26, 0
        BR32 p1, .bar
        ADDI32 r16, r0, ']'
        ADDI32 r23, r0, SYS_PUTC
        SYSCALL
        LOAD32_32 r26, r0, TIMER_COUNT  ; 少し待つ。キーが来たら終わり
.wait:  ADDI32 r23, r0, SYS_KBHIT
        SYSCALL
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
.key:   ADDI32 r23, r0, SYS_GETC        ; 押したキーは捨てる
        SYSCALL
        STORE32_32 r0, r0, LED
        ADDI32 r16, r0, 10
        ADDI32 r23, r0, SYS_PUTC
        SYSCALL
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

s_msg:  .asciz "LED chaser - press any key to stop.\n"
