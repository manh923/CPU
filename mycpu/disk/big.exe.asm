; BIG.EXE — SDRAM に読み込まれて動くプログラムの例（.org 0x1000000 で書くと、mkdisk が SDRAM 用の .EXE にする）
; MyDOS はスタックも SDRAM の末尾に置く。ここでは、自分の番地とスタックの番地を出し、深い再帰（1 万段）をする
SYS_PUTS    = 2
SYS_PUTHEX  = 7
SYS_PUTDEC  = 6

        .org 0x01000000
start:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        ADDI32 r16, r0, s_pc
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, pc, r0
        ADDI32 r23, r0, SYS_PUTHEX
        SYSCALL
        ADDI32 r16, r0, s_sp
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, sp, r0
        ADDI32 r23, r0, SYS_PUTHEX
        SYSCALL
        ADDI32 r16, r0, s_rec
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDI32 r16, r0, 10000
        CALL32 depth
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, s_end
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; depth(n)：n 段まで再帰して、段の数を返す（1 段に 16 バイトのスタック）
depth:
        CMPEQI32 p1, r16, 0
        BR32 p1, .zero
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        ADDI32 r16, r16, -1
        CALL32 depth
        ADDI32 r16, r16, 1
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 16
        RET32
.zero:  RET32

s_pc:   .asciz "Hello from SDRAM! PC = "
s_sp:   .asciz ", SP = "
s_rec:  .asciz "\nRecursion depth: "
s_end:  .asciz "\n"
