; FIB.EXE [n] — フィボナッチ数を 0 番から n 番まで（n は 0〜47、なければ 20）
SYS_PUTC    = 1
SYS_PUTS    = 2
SYS_PUTDEC  = 6

        .org 0x26000
start:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        ; 引数を 10 進で読む
        ADDI32 r24, r0, 0               ; n
        ADDI32 r25, r0, 0               ; 読んだ桁数
.digit: LOAD8U_32 r17, r16, 0
        ADDI32 r17, r17, -'0'
        CMPGEUI32 p1, r17, 10
        BR32 p1, .parsed
        MULI32 r24, r24, 10
        ADDR32 r24, r24, r17
        ADDI32 r16, r16, 1
        ADDI32 r25, r25, 1
        JMP32 .digit
.parsed:
        ADDI32 r17, r0, 20
        CMPEQI32 p1, r25, 0
        SEL32 r24, r17, r24, p1
        ADDI32 r17, r0, 47              ; fib(47) までが 32bit に入る
        CMPLTUI32 p1, r24, 48
        SEL32 r24, r24, r17, p1
        ADDI32 r25, r0, 0               ; a
        ADDI32 r26, r0, 1               ; b
        ADDI32 r27, r0, 0               ; i
.loop:  ADDI32 r16, r0, s1
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, r27, r0
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, s2
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, r25, r0
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, 10
        ADDI32 r23, r0, SYS_PUTC
        SYSCALL
        ADDR32 r17, r25, r26
        ADDR32 r25, r26, r0
        ADDR32 r26, r17, r0
        ADDI32 r27, r27, 1
        CMPGEUR32 p1, r24, r27
        BR32 p1, .loop
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

s1:     .asciz "fib("
s2:     .asciz ") = "
