; pipeline.asm — パイプラインの衝突（ハザード）をわざと起こして、答えが合うか確かめる
; どの命令もすぐ前の命令の結果を使う。答えは自分で確かめて UART に OK / NG を出し、最後に NG の数を出す。
; テスト（test/run.js）は、シミュレータと Verilog で実行した命令の順番も 1 つずつ比べる
; （UART に出す部分 io_begin〜io_end は、送信を待つ回数が違うので比べない）。
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
DATA        = 0x00020100                ; 作業用（内蔵 RAM）
SMC         = 0x00021000                ; 書き換えるコードを写す先（内蔵 RAM）
SDRAM       = 0x01000000

start:
        ADDI32 sp, r0, 0x0002C000
        ADDI32 r30, r0, 0               ; NG の数
        ADDI32 evec, r0, handler

        ; ---- 1. 演算の結果をすぐ次で使う ----
        ADDI32 r29, r0, n_alu
        ADDI32 r16, r0, 1
        ADDR32 r16, r16, r16
        ADDR32 r16, r16, r16
        ADDR32 r16, r16, r16
        SHLI32 r16, r16, 2
        ADDI32 r16, r16, 3
        XORI32 r16, r16, 0x55
        MULR32 r16, r16, r16            ; ((8 << 2) + 3) ^ 0x55 = 0x76 → 0x76 * 0x76
        ADDI32 r17, r0, 0x3664
        CALL32 check

        ; ---- 2. 読み出した値をすぐ次で使う ----
        ADDI32 r29, r0, n_load
        ADDI32 r17, r0, 0x1234
        STORE32_32 r17, r0, DATA
        LOAD32_32 r18, r0, DATA
        ADDI32 r16, r18, 1
        LOAD16U_32 r18, r0, DATA
        CMPEQI32 p1, r18, 0x1234        ; 読んだ値で比べて、すぐ分岐
        BR32 p1, .l2
        ADDI32 r16, r16, 0x100          ; ここは通らない
.l2:    LOAD8S_32 r18, r0, DATA         ; 0x34
        ADDR32 r16, r16, r18
        ADDI32 r17, r0, 0x1235 + 0x34
        CALL32 check

        ; ---- 3. LR・SP に読んで、すぐ RET・SP で使う ----
        ADDI32 r29, r0, n_lrsp
        ADDI32 r17, r0, .l3
        STORE32_32 r17, r0, DATA + 4
        ADDR32 r24, sp, r0
        ADDI32 r16, r0, 0
        LOAD32_32 lr, r0, DATA + 4
        RET32                           ; .l3 へ
        ADDI32 r16, r0, 0x999           ; ここは通らない
.l3:    ADDI32 r17, r0, 0x0002B000
        STORE32_32 r17, r0, DATA + 8
        LOAD32_32 sp, r0, DATA + 8
        STORE32_32 r17, sp, -4          ; 読んだばかりの SP で書く
        LOAD32_32 r16, r0, 0x0002AFFC
        ADDR32 sp, r24, r0
        CALL32 check

        ; ---- 4. 読み出しの後、同じレジスタに別の命令が書く（後の命令が勝つ） ----
        ADDI32 r29, r0, n_waw
        LOAD32_32 r16, r0, DATA
        ADDI32 r16, r0, 5
        ADDI32 r17, r0, 0x77
        STORE32_32 r17, r0, SDRAM + 0x100
        LOAD32_32 r18, r0, SDRAM + 0x100 ; SDRAM（遅い）から読んでいる間に
        ADDI32 r18, r0, 7               ; 同じレジスタに書く
        ADDR32 r16, r16, r18
        LOAD32_32 r19, r0, SDRAM + 0x100
        ADDR32 r16, r16, r19            ; 5 + 7 + 0x77
        ADDI32 r17, r0, 5 + 7 + 0x77
        CALL32 check

        ; ---- 5. 比べた結果（1bit レジスタ）をすぐ次で使う ----
        ADDI32 r29, r0, n_pred
        ADDI32 r16, r0, 0
        ADDI32 r20, r0, 3
        CMPLTI32 p2, r20, 5
        SEL32 r16, r20, r0, p2          ; p2 = 1 → 3
        CMPGEI32 p3, r20, 5
        BR32 p3, .l5                    ; p3 = 0 → 飛ばない
        ADDI32 r16, r16, 0x10
.l5:    CMPEQR32 p4, r20, r20
        BTOI32 r18, p4                  ; 1bit レジスタを値にして
        ADDR32 r16, r16, r18            ; すぐ使う
        ADDI32 r17, r0, 3 + 0x10 + 1
        CALL32 check

        ; ---- 6. 分岐の後ろの命令は実行しない ----
        ADDI32 r29, r0, n_shadow
        ADDI32 r16, r0, 0
        JMP32 .l6a
        ADDI32 r16, r16, 1              ; ここは通らない
        ADDI32 r16, r16, 2
.l6a:   CALL32 ret_now                  ; すぐ戻るだけの関数
        ADDI32 r16, r16, 4
        ADDI32 r18, r0, .l6b
        JMPR32 r18
        ADDI32 r16, r16, 8              ; ここは通らない
.l6b:   ADDI32 r18, r0, ret_now
        CALLR32 r18
        ADDI32 r16, r16, 16
        ADDR32 r18, pc, r0              ; r48 はその命令の番地
        ADDI32 r19, r0, .l6c
.l6c:   SUBR32 r18, r19, r18            ; .l6c − （ADDR32 の番地）= 16
        ADDR32 r16, r16, r18
        ADDI32 r17, r0, 4 + 16 + 16
        CALL32 check

        ; ---- 7. 自分を書き換えるコード ----
        ADDI32 r29, r0, n_smc
        ADDI32 r17, r0, smc_rom         ; 内蔵 RAM に写す
        ADDI32 r18, r0, SMC
.cp:    LOAD32_32 r19, r17, 0
        STORE32_32 r19, r18, 0
        ADDI32 r17, r17, 4
        ADDI32 r18, r18, 4
        CMPLTUI32 p1, r17, smc_end
        BR32 p1, .cp
        ADDI32 r17, r0, 0x111
        ADDI32 r18, r0, SMC
        CALLR32 r18
        ADDR32 r24, r16, r0             ; 1 回目：0x111 × 3
        ADDI32 r17, r0, 0x222
        CALL32 SMC                      ; 2 回目（前に書き換えた値を、また書き換える）
        ADDR32 r16, r16, r24
        ADDI32 r17, r0, 0x111 * 3 + 0x222 * 3
        CALL32 check

        ; ---- 8. M 形式・SWAP・割り算の結果をすぐ使う ----
        ADDI32 r29, r0, n_mem
        ADDI32 r17, r0, 40
        STORE32_32 r17, r0, DATA + 12
        ADDI32 r18, r0, DATA
        ADD32 r16, r17, r18, 12         ; 40 + [DATA + 12] = 80
        ADDI32 r19, r0, 9
        SWAP32 r20, r18, r19, 12        ; r20 = 40、[DATA + 12] = 9
        ADDR32 r16, r16, r20            ; 120
        LOAD32_32 r20, r0, DATA + 12
        ADDR32 r16, r16, r20            ; 129
        DIVUI32 r16, r16, 3             ; 43
        ADDI32 r16, r16, 1
        REMUI32 r20, r16, 5             ; 44 % 5 = 4
        MULR32 r16, r16, r20            ; 176
        STORE8_32 r16, r0, DATA + 16    ; バイトで書いてワードで読む
        LOAD32_32 r20, r0, DATA + 16
        ANDI32 r20, r20, 0xFF
        ADDR32 r16, r16, r20            ; 352
        ADDI32 r17, r0, 352
        CALL32 check

        ; ---- 9. 例外：読み出しの直後、0 で割る、整列違反、SYSCALL、ずれた飛び先 ----
        ADDI32 r29, r0, n_exc
        ADDI32 r27, r0, 0               ; 例外の回数
        ADDI32 r28, r0, 0               ; CAUSE と EPC の合計
        ADDI32 r17, r0, 0x5A
        STORE32_32 r17, r0, DATA + 20
        ADDI32 r26, r0, .e1
        LOAD32_32 r25, r0, DATA + 20    ; 読み出しが終わる前に
        DIVUI32 r16, r25, 0             ; 0 で割る（cause 4）
        ADDI32 r25, r0, 0               ; ここは通らない
.e1:    ADDI32 r26, r0, .e2
        LOAD32_32 r16, r0, DATA + 2     ; 整列違反（cause 1）
.e2:    ADDI32 r26, r0, .e3
        SYSCALL                         ; cause 3
.e3:    ADDI32 r26, r0, .e4
        ADDI32 r18, r0, .e4 + 2
        JMPR32 r18                      ; ずれた番地へ飛ぶ（cause 1、EPC は飛び先）
.e4:    ADDI32 evec, r0, handler2       ; EVEC を書いてすぐ SYSCALL
        SYSCALL
        ADDI32 r27, r27, 100            ; handler2 から戻るとここ（SYSCALL の次）
        ADDI32 evec, r0, handler
        ADDR32 r16, r27, r25            ; 例外 5 回 + 100 + 0x5A
        ADDR32 r16, r16, r28
        ADDI32 r17, r0, 5 + 100 + 0x5A + 4 + 1 + 3 + 1 + 3 + 0
        CALL32 check

        ; ---- 終わり ----
        ADDI32 r16, r0, s_done
        CALL32 puts
        ADDR32 r16, r30, r0
        CALL32 putdec
        ADDI32 r16, r0, s_errors
        CALL32 puts
        HLT

; ret_now()：すぐ戻る
ret_now:
        RET32

; 例外ハンドラ：回数と CAUSE を数えて、r26 の番地へ戻る
handler:
        ADDI32 r27, r27, 1
        ADDR32 r28, r28, cause
        ADDR32 epc, r26, r0
        ERET
; 2 つ目のハンドラ：EVEC を書いた直後の SYSCALL がこちらに来るか
handler2:
        ADDI32 r27, r27, 1
        ADDR32 r28, r28, cause
        ADDI32 epc, epc, 4              ; SYSCALL は 4 バイト
        ERET

; ---- 内蔵 RAM に写して動かす：すぐ後ろ・2 つ後ろ・3 つ後ろの命令の即値を書き換える ----
        .align 16
smc_rom:
        .phase SMC
smc:    STORE32_32 r17, r0, smc_a + 4
smc_a:  ADDI32 r16, r0, 1               ; すぐ後ろ → r16 = r17
        STORE32_32 r17, r0, smc_c + 4
        ADDI32 r20, r0, 0
smc_c:  ADDI32 r21, r0, 1               ; 2 つ後ろ → r21 = r17
        STORE32_32 r17, r0, smc_f + 4
        ADDI32 r20, r0, 0
        ADDI32 r20, r0, 0
smc_f:  ADDI32 r22, r0, 1               ; 3 つ後ろ → r22 = r17
        ADDR32 r16, r16, r21
        ADDR32 r16, r16, r22
        RET32
        .align 16
        .dephase
smc_end:

; ---- ここから下は UART に出す部分（シミュレータと命令の順番を比べない） ----
io_begin:
; check(r16 = 結果, r17 = 正しい値)：r29 の名前と OK / NG を出す
check:
        ADDR32 r23, lr, r0
        ADDR32 r24, r16, r0
        ADDR32 r25, r17, r0
        ADDR32 r16, r29, r0
        CALL32 puts
        CMPEQR32 p1, r24, r25
        BR32 p1, .ok
        ADDI32 r30, r30, 1
        ADDI32 r16, r0, s_ng
        CALL32 puts
        ADDR32 r16, r24, r0
        CALL32 putdec
        ADDI32 r16, r0, s_want
        CALL32 puts
        ADDR32 r16, r25, r0
        CALL32 putdec
        ADDI32 r16, r0, 10
        CALL32 putc
        JMPR32 r23
.ok:    ADDI32 r16, r0, s_ok
        CALL32 puts
        JMPR32 r23

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
io_end:

decbuf      = 0x00020000
n_alu:    .asciz "1 ALU -> ALU          : "
n_load:   .asciz "2 load -> use         : "
n_lrsp:   .asciz "3 load lr / sp        : "
n_waw:    .asciz "4 load, then overwrite: "
n_pred:   .asciz "5 compare -> use p    : "
n_shadow: .asciz "6 branch shadow       : "
n_smc:    .asciz "7 self-modifying code : "
n_mem:    .asciz "8 M-form / SWAP / DIV : "
n_exc:    .asciz "9 exceptions          : "
s_ok:     .asciz "OK\n"
s_ng:     .asciz "NG "
s_want:   .asciz " (want "
s_done:   .asciz "pipeline test: "
s_errors: .asciz " NG\n"
