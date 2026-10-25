; sdram.asm — SDRAM（0x0100_0000〜0x017F_FFFF、8MB）を試す
;   1. データ線：1 の立つ bit を 1 つずつずらして書いて読む
;   2. アドレス線：0x0100_0000 + 2^k（k = 2〜22）にそれぞれ違う値を書き、混ざっていないか
;   3. バイト・ハーフワードの書き込みと、符号付き・なしの読み出し
;   4. 16KB を数で埋めて読み戻し、合計を出す
;   5. SDRAM にプログラムを写して実行。スタックも SDRAM に置いて再帰（fib）
;   6. SDRAM のコードを実行してから書き換え、もう一度実行（Verilog では命令キャッシュに入っている）
; 結果は UART に出す。シミュレータと Verilog（tb/sdram_model.v）で同じになる
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
SDRAM       = 0x01000000
SDRAM_END   = 0x01800000
CODE        = 0x01700000                ; プログラムを写す先
decbuf      = 0x00020000                ; putdec の作業用（内蔵 RAM）

start:
        ADDI32 sp, r0, 0x0002C000
        ADDI32 r24, r0, 0               ; 間違いの数

        ; ---- 1. データ線 ----
        ADDI32 r16, r0, s_data
        CALL32 puts
        ADDI32 r25, r0, 1
.dl:    STORE32_32 r25, r0, SDRAM
        XORI32 r17, r25, -1
        STORE32_32 r17, r0, SDRAM + 4   ; 線に別の値を流してから読む
        LOAD32_32 r18, r0, SDRAM
        CMPNER32 p1, r18, r25
        BR32 p1, .dbad
.dnext: SHLI32 r25, r25, 1
        CMPNEI32 p1, r25, 0
        BR32 p1, .dl
        CALL32 result
        JMP32 .addr
.dbad:  ADDI32 r24, r24, 1
        JMP32 .dnext

        ; ---- 2. アドレス線 ----
.addr:  ADDI32 r16, r0, s_addr
        CALL32 puts
        ADDI32 r17, r0, 0x5A5A0000
        STORE32_32 r17, r0, SDRAM
        ADDI32 r25, r0, 4
.aw:    ORI32 r17, r25, 0x0000A000      ; 番地ごとに違う値
        STORE32_32 r17, r25, SDRAM
        SHLI32 r25, r25, 1
        CMPLTUI32 p1, r25, 0x00800000
        BR32 p1, .aw
        LOAD32_32 r18, r0, SDRAM
        CMPNEI32 p1, r18, 0x5A5A0000
        BR32 p1, .abad0
.ar0:   ADDI32 r25, r0, 4
.ar:    ORI32 r17, r25, 0x0000A000
        LOAD32_32 r18, r25, SDRAM
        CMPNER32 p1, r18, r17
        BR32 p1, .abad
.anext: SHLI32 r25, r25, 1
        CMPLTUI32 p1, r25, 0x00800000
        BR32 p1, .ar
        CALL32 result
        JMP32 .bytes
.abad0: ADDI32 r24, r24, 1
        JMP32 .ar0
.abad:  ADDI32 r24, r24, 1
        JMP32 .anext

        ; ---- 3. バイト・ハーフワード ----
.bytes: ADDI32 r16, r0, s_bytes
        CALL32 puts
        ADDI32 r25, r0, SDRAM + 0x123450
        ADDI32 r17, r0, 0x11223344
        STORE32_32 r17, r25, 0
        ADDI32 r17, r0, 0xAB
        STORE8_32 r17, r25, 1
        ADDI32 r17, r0, 0xCDEF
        STORE16_32 r17, r25, 2
        LOAD32_32 r16, r25, 0           ; 0xCDEFAB44
        CALL32 puthex
        ADDI32 r16, r0, ' '
        CALL32 putc
        LOAD8S_32 r16, r25, 1           ; 0xFFFFFFAB
        CALL32 puthex
        ADDI32 r16, r0, ' '
        CALL32 putc
        LOAD16U_32 r16, r25, 2          ; 0x0000CDEF
        CALL32 puthex
        ADDI32 r16, r0, 10
        CALL32 putc

        ; ---- 4. 16KB を埋めて読み戻す ----
        ADDI32 r16, r0, s_fill
        CALL32 puts
        ADDI32 r25, r0, 0
        ADDI32 r26, r0, 0x13579BDF
.fw:    STORE32_32 r26, r25, SDRAM + 0x400000
        MULI32 r26, r26, 1103515245
        ADDI32 r26, r26, 12345
        ADDI32 r25, r25, 4
        CMPLTUI32 p1, r25, 0x4000
        BR32 p1, .fw
        ADDI32 r25, r0, 0
        ADDI32 r27, r0, 0               ; 合計
.fr:    LOAD32_32 r17, r25, SDRAM + 0x400000
        ADDR32 r27, r27, r17
        SHLI32 r18, r27, 1              ; 順番も効くように回す
        SHRI32 r27, r27, 31
        ORR32 r27, r27, r18
        ADDI32 r25, r25, 4
        CMPLTUI32 p1, r25, 0x4000
        BR32 p1, .fr
        ADDR32 r16, r27, r0
        CALL32 puthex
        ADDI32 r16, r0, 10
        CALL32 putc

        ; ---- 5. SDRAM で実行 ----
        ADDI32 r16, r0, s_run
        CALL32 puts
        ADDI32 r17, r0, code_rom        ; 写す
        ADDI32 r18, r0, CODE
.cp:    LOAD32_32 r19, r17, 0
        STORE32_32 r19, r18, 0
        ADDI32 r17, r17, 4
        ADDI32 r18, r18, 4
        CMPLTUI32 p1, r17, code_rom_end
        BR32 p1, .cp
        ADDR32 r28, sp, r0              ; スタックも SDRAM に
        ADDI32 sp, r0, SDRAM_END
        ADDI32 r16, r0, 12
        ADDI32 r17, r0, sd_fib
        CALLR32 r17
        ADDR32 sp, r28, r0
        CALL32 putdec                   ; fib(12) = 144
        ADDI32 r16, r0, 10
        CALL32 putc

        ; ---- 6. SDRAM のコードを書き換える ----
        ADDI32 r16, r0, s_smc
        CALL32 puts
        CALL32 sd_k                     ; r16 = 1（ここで命令キャッシュに入る）
        ADDR32 r25, r16, r0
        ADDI32 r17, r0, 0x55
        STORE32_32 r17, r0, sd_k + 4    ; ADDI32 の即値を書き換える
        CALL32 sd_k                     ; r16 = 0x55
        SHLI32 r25, r25, 8
        ORR32 r25, r25, r16
        CMPEQI32 p1, r25, 0x155
        BR32 p1, .smcok
        ADDI32 r24, r24, 1
.smcok: CALL32 result

        CMPNEI32 p1, r24, 0
        BR32 p1, .ng
        ADDI32 r16, r0, s_ok
        CALL32 puts
        HLT
.ng:    ADDR32 r16, r24, r0
        CALL32 putdec
        ADDI32 r16, r0, s_ng
        CALL32 puts
        HLT

; ---- ここから UART に出す部分（テストはシミュレータと命令の順番を比べない。送信を待つ回数が違う） ----
io_begin:
; result()：r24（間違いの数）が 0 なら OK、でなければ NG
result:
        ADDR32 r20, lr, r0
        ADDI32 r16, r0, s_pass
        CMPEQI32 p1, r24, 0
        BR32 p1, .p
        ADDI32 r16, r0, s_fail
.p:     CALL32 puts
        JMPR32 r20

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

; puthex(r16)：16 進 8 桁。r16〜r22 を壊す
puthex:
        ADDR32 r22, lr, r0
        ADDR32 r21, r16, r0
        ADDI32 r20, r0, 28
.h:     SHRR32 r16, r21, r20
        ANDI32 r16, r16, 15
        ADDI32 r16, r16, '0'
        CMPLTUI32 p1, r16, '9' + 1
        BR32 p1, .d
        ADDI32 r16, r16, 'A' - '9' - 1
.d:     CALL32 putc
        ADDI32 r20, r20, -4
        CMPGEI32 p1, r20, 0
        BR32 p1, .h
        JMPR32 r22

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

io_end:

; ---- ここから SDRAM（CODE）に写して動かす ----
        .align 16
code_rom:
        .phase CODE
; sd_fib(r16) = r16 < 2 ? r16 : sd_fib(r16 - 1) + sd_fib(r16 - 2)
sd_fib:
        CMPLTI32 p1, r16, 2
        BR32 p1, .ret
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r16, r0
        ADDI32 r16, r24, -1
        CALL32 sd_fib
        ADDR32 r25, r16, r0
        ADDI32 r16, r24, -2
        CALL32 sd_fib
        ADDR32 r16, r16, r25
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
.ret:   RET32
sd_k:   ADDI32 r16, r0, 1               ; 6. で即値を書き換える
        RET32
        .align 16
        .dephase
code_rom_end:

s_data:  .asciz "SDRAM data lines    : "
s_addr:  .asciz "SDRAM address lines : "
s_bytes: .asciz "SDRAM byte/half     : "
s_fill:  .asciz "SDRAM 16KB checksum : "
s_run:   .asciz "fib(12) from SDRAM  : "
s_smc:   .asciz "SDRAM code rewrite  : "
s_pass:  .asciz "OK\n"
s_fail:  .asciz "NG\n"
s_ok:    .asciz "SDRAM test passed\n"
s_ng:    .asciz " error(s)\n"
