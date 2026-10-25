; cpi.asm — 命令ごとの速さ（1 命令あたりのクロック数）を Verilog で測る。test/run.js が使う
; 同じ命令を 8 個並べたループを 20 回まわし、タイマー（tb_soc では 1 クロック = 1µs）で時間を測って UART に出す。
; 「名前: クロック数」の 1 行目はループだけの時間。test/run.js が (時間 − ループだけ) ÷ 160 を、
; 行の最後の [上限] と比べる。シミュレータではタイマーの進み方が違うので、Verilog だけで使う。
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
TIMER_COUNT = 0x00010010
decbuf      = 0x00020000

start:  ADDI32 sp, r0, 0x0002C000
        ADDI32 r21, r0, 3
        ADDI32 r26, r0, 0x00021000      ; 内蔵 RAM
        ADDI32 r27, r0, 0x01000000      ; SDRAM
        CMPNER32 p3, r0, r0             ; p3 = 0
        ADDI32 r16, r0, n0
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l0:
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l0
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s0
        CALL32 puts
        ADDI32 r16, r0, n1
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l1:
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l1
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s1
        CALL32 puts
        ADDI32 r16, r0, n2
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l2:
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r20, r20, 1
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l2
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s2
        CALL32 puts
        ADDI32 r16, r0, n3
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l3:
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        CMPEQR32 p2, r20, r21
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l3
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s3
        CALL32 puts
        ADDI32 r16, r0, n4
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l4:
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        MULR32 r20, r20, r21
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l4
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s4
        CALL32 puts
        ADDI32 r16, r0, n5
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l5:
        BR32 p3, 0
        BR32 p3, 0
        BR32 p3, 0
        BR32 p3, 0
        BR32 p3, 0
        BR32 p3, 0
        BR32 p3, 0
        BR32 p3, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l5
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s5
        CALL32 puts
        ADDI32 r16, r0, n6
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l6:
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        LOAD32_32 r20, r26, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l6
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s6
        CALL32 puts
        ADDI32 r16, r0, n7
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l7:
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        LOAD32_32 r0, r26, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l7
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s7
        CALL32 puts
        ADDI32 r16, r0, n8
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l8:
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        STORE32_32 r20, r26, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l8
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s8
        CALL32 puts
        ADDI32 r16, r0, n9
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l9:
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADD32 r20, r20, r26, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l9
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s9
        CALL32 puts
        ADDI32 r16, r0, n10
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l10:
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        LOAD32_32 r20, r27, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l10
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s10
        CALL32 puts
        ADDI32 r16, r0, n11
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l11:
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        STORE32_32 r20, r27, 0
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l11
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s11
        CALL32 puts
        ADDI32 r16, r0, n12
        CALL32 puts
        ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
l12:
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        DIVUR32 r20, r20, r21
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, l12
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CALL32 putdec
        ADDI32 r16, r0, s12
        CALL32 puts
        ; SDRAM に置いたコード（命令キャッシュ）：ADDR32 × 8 のループを SDRAM に写して呼ぶ。最初のライン読み込みも込み
        ADDI32 r16, r0, n13
        CALL32 puts
        ADDI32 r17, r0, sdcode_rom
        ADDI32 r18, r0, 0x01000000 + 0x1000
.cp:    LOAD32_32 r19, r17, 0
        STORE32_32 r19, r18, 0
        ADDI32 r17, r17, 4
        ADDI32 r18, r18, 4
        CMPLTUI32 p1, r17, sdcode_end
        BR32 p1, .cp
        CALL32 0x01000000 + 0x1000
        CALL32 putdec
        ADDI32 r16, r0, s13
        CALL32 puts
        HLT

        .align 16
sdcode_rom:
        .phase 0x01000000 + 0x1000
sdloop: ADDI32 r25, r0, 20
        LOAD32_32 r24, r0, TIMER_COUNT
.l:     ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r21
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, .l
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        RET32
        .align 16
        .dephase
sdcode_end:

; puts(r16)。r16〜r19 を壊す
puts:
        ADDR32 r19, lr, r0
        ADDR32 r18, r16, r0
.n:     LOAD8U_32 r16, r18, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .e
        CALL32 putc
        ADDI32 r18, r18, 1
        JMP32 .n
.e:     JMPR32 r19

; putc(r16)：\n の前に \r。r17 を壊す
putc:
        CMPEQI32 p2, r16, 10
        BR32 p2, .crlf
.w:     LOAD32_32 r17, r0, UART_STATUS
        ANDI32 r17, r17, 1
        CMPEQI32 p2, r17, 0
        BR32 p2, .w
        STORE32_32 r16, r0, UART_TX
        RET32
.crlf:  LOAD32_32 r17, r0, UART_STATUS
        ANDI32 r17, r17, 1
        CMPEQI32 p2, r17, 0
        BR32 p2, .crlf
        ADDI32 r17, r0, 13
        STORE32_32 r17, r0, UART_TX
        JMP32 .w

; putdec(r16)：符号なし 10 進。数字を下の桁から decbuf にためて、逆順に出す。r16〜r22 を壊す
putdec:
        ADDR32 r22, lr, r0
        ADDI32 r21, r0, decbuf
.div:   REMUI32 r18, r16, 10
        DIVUI32 r16, r16, 10
        ADDI32 r18, r18, '0'
        STORE8_32 r18, r21, 0
        ADDI32 r21, r21, 1
        CMPNEI32 p1, r16, 0
        BR32 p1, .div
.out:   ADDI32 r21, r21, -1
        LOAD8U_32 r16, r21, 0
        CALL32 putc
        CMPNEI32 p1, r21, decbuf
        BR32 p1, .out
        JMPR32 r22

n0: .asciz "loop: "
s0: .asciz " [0]\n"
n1: .asciz "ADDR32: "
s1: .asciz " [1.0]\n"
n2: .asciz "ADDI32: "
s2: .asciz " [1.0]\n"
n3: .asciz "CMPEQR32: "
s3: .asciz " [1.0]\n"
n4: .asciz "MULR32: "
s4: .asciz " [1.0]\n"
n5: .asciz "BR (not taken): "
s5: .asciz " [1.0]\n"
n6: .asciz "LOAD32 RAM: "
s6: .asciz " [2.0]\n"
n7: .asciz "LOAD32 RAM (other reg): "
s7: .asciz " [1.0]\n"
n8: .asciz "STORE32 RAM: "
s8: .asciz " [1.0]\n"
n9: .asciz "ADD32 M-form: "
s9: .asciz " [3.0]\n"
n10: .asciz "LOAD32 SDRAM: "
s10: .asciz " [7.0]\n"
n11: .asciz "STORE32 SDRAM: "
s11: .asciz " [6.0]\n"
n12: .asciz "DIVUR32: "
s12: .asciz " [34.0]\n"
n13: .asciz "ADDR32 in SDRAM (I-cache): "
s13: .asciz " [1.4]\n"
