; HELLO.EXE — 引数があれば「Hello, 引数!」、なければ「Hello, World!」
; MyDOS は r16 に引数の文字列を渡して、ユーザーモードで開始番地から実行する。RET32 で C:\> に戻る。
; OS の機能は SYSCALL で呼ぶ（r23 = 機能番号。番号は mydos.sys.asm の先頭）
SYS_PUTS    = 2

        .org 0x26000
start:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        LOAD8U_32 r17, r24, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .world
        ADDI32 r16, r0, s_hello
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDR32 r16, r24, r0
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDI32 r16, r0, s_end
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        JMP32 .ret
.world: ADDI32 r16, r0, s_world
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

s_hello: .asciz "Hello, "
s_end:   .asciz "!\n"
s_world: .asciz "Hello, World!\n"
