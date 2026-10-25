; CRASH.EXE — わざと 0 で割る。ユーザーモードで動いているので、機械は止まらず
; MyDOS が "Program terminated" を出して C:\> に戻る
SYS_PUTS    = 2

        .org 0x26000
start:
        ADDI32 r16, r0, s_msg
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        ADDI32 r16, r0, 1
        DIVI32 r16, r16, 0
        ADDI32 r16, r0, s_never
        ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        RET32

s_msg:   .asciz "Dividing by zero...\n"
s_never: .asciz "(this line is never printed)\n"
