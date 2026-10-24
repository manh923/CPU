; fib.asm — 再帰呼び出しでフィボナッチ数を求め、10 進で UART に出す
; 呼び出し規約（8 章）：引数・戻り値 r16、r24〜r31 は呼ばれた側が保存、LR は呼ぶ側の関数が退避
UART_TX     = 0x00010000
UART_STATUS = 0x00010004

start:
        ADDI32 sp, r0, 0x00028000
        ADDI32 r24, r0, 0               ; n
.loop:  ADDR32 r16, r24, r0
        CALL32 fib
        ADDR32 r25, r16, r0
        ; "fib(n) = x" を出す
        ADDI32 r16, r0, s1
        CALL32 puts
        ADDR32 r16, r24, r0
        CALL32 putdec
        ADDI32 r16, r0, s2
        CALL32 puts
        ADDR32 r16, r25, r0
        CALL32 putdec
        ADDI32 r16, r0, 10
        CALL32 putc
        ADDI32 r24, r24, 1
        CMPLTI32 p1, r24, 21
        BR32 p1, .loop
        HLT

; fib(n) = n < 2 ? n : fib(n-1) + fib(n-2)
fib:
        CMPLTI32 p1, r16, 2
        BR32 p1, .ret
        ADDI32 sp, sp, -16              ; LR・r24・r25 を退避（SP は 8 の倍数に保つ）
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r16, r0
        ADDI32 r16, r24, -1
        CALL32 fib
        ADDR32 r25, r16, r0
        ADDI32 r16, r24, -2
        CALL32 fib
        ADDR32 r16, r16, r25
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
.ret:   RET32

; putdec: r16 を符号なし 10 進で出す。スタックに数字をためて逆順に出す
putdec:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, sp, r0              ; 数字を積む前の SP
.div:   REMUI32 r17, r16, 10
        DIVUI32 r16, r16, 10
        ADDI32 r17, r17, '0'
        ADDI32 sp, sp, -8
        STORE8_32 r17, sp, 0
        CMPNEI32 p1, r16, 0
        BR32 p1, .div
.out:   LOAD8U_32 r16, sp, 0
        ADDI32 sp, sp, 8
        CALL32 putc
        CMPNER32 p1, sp, r24
        BR32 p1, .out
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 16
        RET32

; puts: r16 の文字列を出す
puts:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        ADDR32 r18, r16, r0
.next:  LOAD8U_32 r16, r18, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        CALL32 putc
        ADDI32 r18, r18, 1
        JMP32 .next
.end:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; putc: r16 の 1 文字を出す（\n の前に \r）
putc:
        CMPNEI32 p2, r16, 10
        BR32 p2, .raw
        ADDI32 r20, r0, 13
.w0:    LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p3, r19, 0
        BR32 p3, .w0
        STORE32_32 r20, r0, UART_TX
.raw:   LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p3, r19, 0
        BR32 p3, .raw
        STORE32_32 r16, r0, UART_TX
        RET32

s1:     .asciz "fib("
s2:     .asciz ") = "
