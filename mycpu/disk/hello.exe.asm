; HELLO.EXE — 引数があれば「Hello, 引数!」、なければ「Hello, World!」
; MyDOS は r16 に引数の文字列を渡して開始番地を呼ぶ。RET32 で C:\> に戻る。
BIOS_PUTS   = 0x18

        .org 0x23000
start:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        LOAD8U_32 r17, r24, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .world
        ADDI32 r16, r0, s_hello
        CALL32 BIOS_PUTS
        ADDR32 r16, r24, r0
        CALL32 BIOS_PUTS
        ADDI32 r16, r0, s_end
        CALL32 BIOS_PUTS
        JMP32 .ret
.world: ADDI32 r16, r0, s_world
        CALL32 BIOS_PUTS
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

s_hello: .asciz "Hello, "
s_end:   .asciz "!\n"
s_world: .asciz "Hello, World!\n"
