; SIEVE.EXE [n] — n より小さい素数を数える（エラトステネスのふるい。n は 2〜8388608、なければ 1000000）
; ふるいの表（1 バイト × n）は SDRAM（0x0100_0000〜、8MB）に置く。内蔵 RAM には入らない大きさ
SYS_PUTC    = 1
SYS_PUTS    = 2
SYS_PUTDEC  = 6
SDRAM       = 0x01000000
SDRAM_SIZE  = 0x00800000

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
        CMPLTUI32 p1, r25, 8            ; 8 桁まで
        BR32 p1, .digit
.parsed:
        ADDI32 r17, r0, 1000000
        CMPEQI32 p1, r25, 0
        SEL32 r24, r17, r24, p1
        ADDI32 r17, r0, SDRAM_SIZE
        CMPLTUI32 p1, r24, SDRAM_SIZE + 1
        SEL32 r24, r24, r17, p1
        ADDI32 r17, r0, 2
        CMPLTUI32 p1, r24, 2
        SEL32 r24, r17, r24, p1

        ADDI32 r16, r0, s_clear
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ; 表を 0 にする（4 バイトずつ）
        ADDI32 r17, r0, SDRAM
        ADDI32 r18, r24, SDRAM + 3
.clr:   STORE32_32 r0, r17, 0
        ADDI32 r17, r17, 4
        CMPLTUR32 p1, r17, r18
        BR32 p1, .clr

        ; i × i < n の i について、i が素数なら i × i, i × i + i, … に印を付ける
        ADDI32 r25, r0, 2               ; i
        ADDI32 r19, r0, 1
.outer: MULR32 r17, r25, r25
        CMPGEUR32 p1, r17, r24
        BR32 p1, .count
        LOAD8U_32 r18, r25, SDRAM
        CMPNEI32 p1, r18, 0
        BR32 p1, .next
.mark:  STORE8_32 r19, r17, SDRAM
        ADDR32 r17, r17, r25
        CMPLTUR32 p1, r17, r24
        BR32 p1, .mark
.next:  ADDI32 r25, r25, 1
        JMP32 .outer

        ; 印のない数を数える。いちばん大きいものも覚えておく
.count: ADDI32 r25, r0, 2
        ADDI32 r26, r0, 0               ; 個数
        ADDI32 r27, r0, 0               ; いちばん大きい素数
.cl:    CMPGEUR32 p1, r25, r24
        BR32 p1, .show
        LOAD8U_32 r18, r25, SDRAM
        CMPNEI32 p1, r18, 0
        BR32 p1, .cn
        ADDI32 r26, r26, 1
        ADDR32 r27, r25, r0
.cn:    ADDI32 r25, r25, 1
        JMP32 .cl

.show:  ADDI32 r16, r0, s_below
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, r24, r0
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, s_colon
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, r26, r0
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, s_largest
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, r27, r0
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, s_end
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL

        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

s_clear:   .asciz "Sieving in SDRAM...\n"
s_below:   .asciz "Primes below "
s_colon:   .asciz ": "
s_largest: .asciz " (largest "
s_end:     .asciz ")\n"
