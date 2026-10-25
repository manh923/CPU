; selftest64.asm — 64bit 命令の自己テスト（64bit CPU 用：sim.js --cpu 64）
; 32bit 命令も混ぜて、上位互換（3.3）も確かめる。
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
DATA        = 0x00020000

start:
        ADDI32 sp, r0, 0x00028000

        ADDI32 r31, r0, 1               ; 64bit の即値がまるごと入る
        ADDI64 r32, r0, 0x123456789ABCDEF0
        ADDI64 r33, r0, 0xFEDCBA9876543210
        ADDR64 r40, r32, r33
        CMPNEI64 p1, r40, 0x1111111111111100
        BR64 p1, fail

        ADDI32 r31, r0, 2
        MULR64 r40, r32, r33
        CMPNEI64 p1, r40, 0x236D88FE5618CF00
        BR64 p1, fail
        MULHR64 r40, r32, r33
        CMPNEI64 p1, r40, 0xFFEB49923CC09532
        BR64 p1, fail
        MULHUR64 r40, r32, r33
        CMPNEI64 p1, r40, 0x121FA00AD77D7422
        BR64 p1, fail

        ADDI32 r31, r0, 3
        DIVUI64 r40, r32, 0x12345
        CMPNEI64 p1, r40, 0x100005B00205
        BR64 p1, fail
        REMUI64 r40, r32, 0x12345
        CMPNEI64 p1, r40, 0xA497
        BR64 p1, fail
        ADDI64 r34, r0, 0x8000000000000000
        DIVI64 r40, r34, -1             ; 最小値 ÷ −1
        CMPNER64 p1, r40, r34
        BR64 p1, fail

        ADDI32 r31, r0, 4
        ADDI64 r34, r0, 1
        SHLI64 r40, r34, 63
        CMPNEI64 p1, r40, 0x8000000000000000
        BR64 p1, fail
        SHLI64 r40, r34, 65             ; 下位 6bit だけ
        CMPNEI64 p1, r40, 2
        BR64 p1, fail
        ADDI64 r34, r0, 0x8000000000000000
        SARI64 r40, r34, 63
        CMPNEI64 p1, r40, -1
        BR64 p1, fail
        SHRI64 r40, r34, 63
        CMPNEI64 p1, r40, 1
        BR64 p1, fail

        ADDI32 r31, r0, 5
        ADDI64 r34, r0, 1
        CLZ64 r40, r34
        CMPNEI64 p1, r40, 63
        BR64 p1, fail
        ADDI64 r34, r0, -1
        POPCNT64 r40, r34
        CMPNEI64 p1, r40, 64
        BR64 p1, fail

        ADDI32 r31, r0, 6               ; 64bit のロード・ストアと 32bit の拡張
        ADDI32 r16, r0, DATA            ; アドレスは 32bit レジスタでもよい
        STORE64_64 r32, r16, 0
        LOAD64_64 r40, r16, 0
        CMPNER64 p1, r40, r32
        BR64 p1, fail
        LOAD32S_64 r40, r16, 4          ; 0x12345678 → 正なのでそのまま
        CMPNEI64 p1, r40, 0x12345678
        BR64 p1, fail
        LOAD32S_64 r40, r16, 0          ; 0x9ABCDEF0 → 符号拡張
        CMPNEI64 p1, r40, 0xFFFFFFFF9ABCDEF0
        BR64 p1, fail
        LOAD32U_64 r40, r16, 0
        CMPNEI64 p1, r40, 0x9ABCDEF0
        BR64 p1, fail
        LOAD32_32 r20, r16, 0           ; 32bit 命令で同じ場所
        CMPNEI32 p1, r20, 0x9ABCDEF0
        BR32 p1, fail

        ADDI32 r31, r0, 7               ; 幅変換
        EXT32TO64S r40, r20
        CMPNEI64 p1, r40, 0xFFFFFFFF9ABCDEF0
        BR64 p1, fail
        EXT32TO64U r40, r20
        CMPNEI64 p1, r40, 0x9ABCDEF0
        BR64 p1, fail
        TRUNC64TO32 r21, r33
        CMPNEI32 p1, r21, 0x76543210
        BR32 p1, fail
        CMPLTR64 p2, r33, r32           ; 符号付き：負 < 正
        BTOI64 r40, p2
        CMPNEI64 p1, r40, 1
        BR64 p1, fail
        SEL64 r40, r32, r33, p2
        CMPNER64 p1, r40, r32
        BR64 p1, fail

        ADDI32 r31, r0, 8               ; 32bit 命令から特殊レジスタに書くと上位は 0（3.3）
        ADDI64 sp, r0, 0x100028000
        ADDI32 sp, sp, 0
        ADDR64 r40, sp, r0
        CMPNEI64 p1, r40, 0x28000
        BR64 p1, fail

        ADDI32 r31, r0, 9               ; 32bit 命令のアドレス計算は 32bit で回る（3.3）
        ADDI64 r34, r0, 0x100000000 + DATA
        LOAD32_32 r20, r34, 0
        CMPNEI32 p1, r20, 0x9ABCDEF0
        BR32 p1, fail
        STORE32_32 r20, sp, -8          ; SP の下（0xFFFFFFF8 を足して 32bit で回る）
        LOAD32_32 r21, sp, -8
        CMPNER32 p1, r20, r21
        BR32 p1, fail

        ADDI32 r31, r0, 10              ; 64bit の呼び出し
        CALL64 func
        CMPNEI64 p1, r40, 4242
        BR64 p1, fail

        ADDI32 r16, r0, pass_msg
        CALL32 puts
        HLT

func:   ADDI64 r40, r0, 4242
        RET64

fail:
        ADDI32 r16, r0, fail_msg
        CALL32 puts
        DIVUI32 r17, r31, 10
        ADDI32 r17, r17, '0'
        CALL32 putc
        REMUI32 r17, r31, 10
        ADDI32 r17, r17, '0'
        CALL32 putc
        ADDI32 r17, r0, 10
        CALL32 putc
        HLT

puts:
        ADDR32 r21, lr, r0
.next:  LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
        CALL32 putc
        ADDI32 r16, r16, 1
        JMP32 .next
.end:   JMPR32 r21

putc:
        LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p1, r19, 0
        BR32 p1, putc
        STORE32_32 r17, r0, UART_TX
        RET32

pass_msg: .asciz "selftest64: PASS\n"
fail_msg: .asciz "selftest64: FAIL "
