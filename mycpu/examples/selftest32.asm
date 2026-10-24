; selftest32.asm — 32bit 命令の自己テスト。全部合えば "selftest32: PASS"、違えば "FAIL nn"
; 各テストは r31 に番号を入れ、結果を r20 に作って期待値と比べる。
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
DATA        = 0x00020000                ; 内蔵 RAM（テストの書き込み先）

start:
        ADDI32 sp, r0, 0x00028000

        ; ---- 算術 ----
        ADDI32 r31, r0, 1
        ADDI32 r16, r0, 5
        ADDI32 r17, r0, 7
        ADDR32 r20, r16, r17
        CMPNEI32 p1, r20, 12
        BR32 p1, fail

        ADDI32 r31, r0, 2               ; 桁あふれは捨てる
        ADDI32 r16, r0, -1
        ADDI32 r20, r16, 1
        CMPNER32 p1, r20, r0
        BR32 p1, fail

        ADDI32 r31, r0, 3
        SUBR32 r20, r17, r16            ; 7 - (-1)
        CMPNEI32 p1, r20, 8
        BR32 p1, fail

        ADDI32 r31, r0, 4               ; M 形式：rd ← rs1 + [rs2 + imm]
        ADDI32 r18, r0, consts
        ADD32 r20, r17, r18, 4          ; 7 + 100
        CMPNEI32 p1, r20, 107
        BR32 p1, fail

        ADDI32 r31, r0, 5
        ADDI32 r16, r0, 0x12345678
        ADDI32 r17, r0, 0x9ABCDEF0
        MULR32 r20, r16, r17
        CMPNEI32 p1, r20, 0x242D2080
        BR32 p1, fail

        ADDI32 r31, r0, 6
        MULHR32 r20, r16, r17
        CMPNEI32 p1, r20, 0xF8CC93D6
        BR32 p1, fail

        ADDI32 r31, r0, 7
        MULHUR32 r20, r16, r17
        CMPNEI32 p1, r20, 0x0B00EA4E
        BR32 p1, fail

        ADDI32 r31, r0, 8               ; 符号付き除算は 0 方向へ切り捨て
        ADDI32 r16, r0, -7
        DIVI32 r20, r16, 2
        CMPNEI32 p1, r20, -3
        BR32 p1, fail

        ADDI32 r31, r0, 9
        REMI32 r20, r16, 2
        CMPNEI32 p1, r20, -1
        BR32 p1, fail

        ADDI32 r31, r0, 10
        ADDI32 r16, r0, 0xFFFFFFFE
        DIVUI32 r20, r16, 2
        CMPNEI32 p1, r20, 0x7FFFFFFF
        BR32 p1, fail

        ADDI32 r31, r0, 11
        ADDI32 r16, r0, 100
        ADDI32 r17, r0, 7
        REMUR32 r20, r16, r17
        CMPNEI32 p1, r20, 2
        BR32 p1, fail

        ADDI32 r31, r0, 12              ; 最小値 ÷ −1 は最小値、余り 0（5.3）
        ADDI32 r16, r0, 0x80000000
        ADDI32 r17, r0, -1
        DIVR32 r20, r16, r17
        CMPNEI32 p1, r20, 0x80000000
        BR32 p1, fail
        REMR32 r20, r16, r17
        CMPNEI32 p1, r20, 0
        BR32 p1, fail

        ; ---- 論理・シフト ----
        ADDI32 r31, r0, 13
        ADDI32 r16, r0, 0xF0F0
        ANDI32 r20, r16, 0x0FF0
        CMPNEI32 p1, r20, 0x00F0
        BR32 p1, fail
        ORI32 r20, r16, 0x0F0F
        CMPNEI32 p1, r20, 0xFFFF
        BR32 p1, fail
        XORI32 r20, r16, -1              ; NOT（5.9）
        CMPNEI32 p1, r20, 0xFFFF0F0F
        BR32 p1, fail

        ADDI32 r31, r0, 14
        ADDI32 r16, r0, 1
        SHLI32 r20, r16, 31
        CMPNEI32 p1, r20, 0x80000000
        BR32 p1, fail
        SHLI32 r20, r16, 33             ; シフト量は下位 5bit だけ（5.4）
        CMPNEI32 p1, r20, 2
        BR32 p1, fail

        ADDI32 r31, r0, 15
        ADDI32 r16, r0, 0x80000000
        SHRI32 r20, r16, 31
        CMPNEI32 p1, r20, 1
        BR32 p1, fail
        ADDI32 r17, r0, 31
        SARR32 r20, r16, r17
        CMPNEI32 p1, r20, -1
        BR32 p1, fail

        ADDI32 r31, r0, 16
        ADDI32 r16, r0, 1
        CLZ32 r20, r16
        CMPNEI32 p1, r20, 31
        BR32 p1, fail
        CLZ32 r20, r0
        CMPNEI32 p1, r20, 32
        BR32 p1, fail
        ADDI32 r16, r0, 0xF0F00001
        POPCNT32 r20, r16
        CMPNEI32 p1, r20, 9
        BR32 p1, fail

        ; ---- 比較・選択 ----
        ADDI32 r31, r0, 17
        ADDI32 r16, r0, -1
        ADDI32 r17, r0, 1
        CMPLTR32 p2, r16, r17           ; 符号付き：-1 < 1
        BTOI32 r20, p2
        CMPNEI32 p1, r20, 1
        BR32 p1, fail
        CMPLTUR32 p2, r16, r17          ; 符号なし：0xFFFFFFFF < 1 ではない
        BTOI32 r20, p2
        CMPNEI32 p1, r20, 0
        BR32 p1, fail
        CMPGEI32 p2, r17, 1
        CMPGEUI32 p3, r17, -1
        SEL32 r20, r16, r17, p2         ; p2 = 1 → r16
        CMPNEI32 p1, r20, -1
        BR32 p1, fail
        SEL32 r20, r16, r17, p3         ; p3 = 0 → r17
        CMPNEI32 p1, r20, 1
        BR32 p1, fail

        ; ---- ロード・ストア ----
        ADDI32 r31, r0, 18
        ADDI32 r18, r0, DATA
        ADDI32 r16, r0, 0x11223380
        STORE32_32 r16, r18, 0
        LOAD8S_32 r20, r18, 0
        CMPNEI32 p1, r20, 0xFFFFFF80
        BR32 p1, fail
        LOAD8U_32 r20, r18, 0
        CMPNEI32 p1, r20, 0x80
        BR32 p1, fail
        LOAD16U_32 r20, r18, 2
        CMPNEI32 p1, r20, 0x1122
        BR32 p1, fail
        ADDI32 r16, r0, 0xABCD
        STORE16_32 r16, r18, 2
        STORE8_32 r16, r18, 1
        LOAD32_32 r20, r18, 0
        CMPNEI32 p1, r20, 0xABCDCD80
        BR32 p1, fail
        LOAD16S_32 r20, r18, 2
        CMPNEI32 p1, r20, 0xFFFFABCD
        BR32 p1, fail

        ADDI32 r31, r0, 19              ; SWAP
        ADDI32 r16, r0, 1234
        SWAP32 r20, r18, r16, 0
        CMPNEI32 p1, r20, 0xABCDCD80
        BR32 p1, fail
        LOAD32_32 r20, r18, 0
        CMPNEI32 p1, r20, 1234
        BR32 p1, fail

        ADDI32 r31, r0, 20              ; スタック：負の即値で SP の下に書く（3.3 の例）
        ADDI32 r16, r0, 77
        STORE32_32 r16, sp, -8
        LOAD32_32 r20, sp, -8
        CMPNEI32 p1, r20, 77
        BR32 p1, fail

        ; ---- 分岐・呼び出し ----
        ADDI32 r31, r0, 21              ; PC を読むと自分自身の番地（3.3）
here:   ADDR32 r20, pc, r0
        CMPNEI32 p1, r20, here
        BR32 p1, fail

        ADDI32 r31, r0, 22
        ADDI32 r16, r0, func
        CALLR32 r16                     ; r20 ← 42
        CMPNEI32 p1, r20, 42
        BR32 p1, fail
        ADDI32 r16, r0, .after
        JMPR32 r16
        JMP32 fail
.after:
        ADDI32 r31, r0, 23              ; r0 への書き込みは無視
        ADDI32 r0, r0, 5
        CMPNER32 p1, r0, r0
        BR32 p1, fail
        CMPNEI32 p1, r0, 0
        BR32 p1, fail

        ADDI32 r31, r0, 24              ; 整数 → 1bit（5.9）
        ADDI32 r16, r0, 3
        CMPNER32 p4, r16, r0
        BR32 p4, .ok24
        JMP32 fail
.ok24:
        ADDI32 r16, r0, pass_msg
        CALL32 puts
        HLT

func:   ADDI32 r20, r0, 42
        RET32

fail:
        ADDI32 r16, r0, fail_msg
        CALL32 puts
        ; r31 を 10 進 2 桁で出す
        DIVUI32 r17, r31, 10
        ADDI32 r17, r17, '0'
        CALL32 putc
        REMUI32 r17, r31, 10
        ADDI32 r17, r17, '0'
        CALL32 putc
        ADDI32 r17, r0, 10
        CALL32 putc
        HLT

; puts: r16 の文字列を出す。r16〜r19, r21 を壊す
puts:
        ADDR32 r21, lr, r0
.next:  LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
        CALL32 putc
        ADDI32 r16, r16, 1
        JMP32 .next
.end:   JMPR32 r21

; putc: r17 の 1 文字を出す。r19 を壊す
putc:
        LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p1, r19, 0
        BR32 p1, putc
        STORE32_32 r17, r0, UART_TX
        RET32

        .align 4
consts: .word 0, 100
pass_msg: .asciz "selftest32: PASS\n"
fail_msg: .asciz "selftest32: FAIL "
