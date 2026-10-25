; TOUPPER.EXE 元 先 — ファイルを大文字にして写す（ファイルの SYSCALL の例）
SYS_PUTS    = 2
SYS_PUTDEC  = 6
SYS_OPEN    = 16                        ; open(名前, モード 0 = 読む / 1 = 新しく書く) → ハンドル
SYS_CLOSE   = 17
SYS_READ    = 18                        ; read(ハンドル, 置き場所, 長さ) → 読んだ長さ
SYS_WRITE   = 19                        ; write(ハンドル, データ, 長さ) → 書いた長さ

        .org 0x26000
start:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        ADDR32 r24, r16, r0             ; 1 つ目の名前
.sp:    LOAD8U_32 r17, r16, 0           ; 空白を 0 にして切り、2 つ目の名前へ
        CMPEQI32 p1, r17, 0
        BR32 p1, .usage
        CMPEQI32 p1, r17, ' '
        BR32 p1, .cut
        ADDI32 r16, r16, 1
        JMP32 .sp
.cut:   STORE8_32 r0, r16, 0
        ADDI32 r16, r16, 1
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, ' '
        BR32 p1, .cut
        CMPEQI32 p1, r17, 0
        BR32 p1, .usage
        ADDR32 r25, r16, r0             ; 2 つ目の名前
        ADDR32 r16, r24, r0
        ADDI32 r17, r0, 0
        ADDI32 r23, r0, SYS_OPEN
        SYSCALL
        CMPLTI32 p1, r16, 0
        BR32 p1, .nofile
        ADDR32 r26, r16, r0             ; r26 = 読むハンドル
        ADDR32 r16, r25, r0
        ADDI32 r17, r0, 1
        ADDI32 r23, r0, SYS_OPEN
        SYSCALL
        CMPLTI32 p1, r16, 0
        BR32 p1, .nocreate
        ADDR32 r25, r16, r0             ; r25 = 書くハンドル
        ADDI32 r27, r0, 0               ; r27 = 合計
.rd:    ADDR32 r16, r26, r0
        ADDI32 r17, r0, buf
        ADDI32 r18, r0, 256
        ADDI32 r23, r0, SYS_READ
        SYSCALL
        CMPLTI32 p1, r16, 1
        BR32 p1, .done
        ADDR32 r18, r16, r0
        ADDR32 r27, r27, r16
        ADDI32 r17, r0, buf             ; 'a'〜'z' を大文字に
        ADDR32 r19, r17, r18
.up:    CMPGEUR32 p1, r17, r19
        BR32 p1, .wr
        LOAD8U_32 r20, r17, 0
        ADDI32 r21, r20, -'a'
        CMPLTUI32 p1, r21, 26
        ADDI32 r21, r20, -32
        SEL32 r20, r21, r20, p1
        STORE8_32 r20, r17, 0
        ADDI32 r17, r17, 1
        JMP32 .up
.wr:    ADDR32 r16, r25, r0
        ADDI32 r17, r0, buf
        ADDI32 r23, r0, SYS_WRITE
        SYSCALL
        JMP32 .rd
.done:  ADDR32 r16, r26, r0
        ADDI32 r23, r0, SYS_CLOSE
        SYSCALL
        ADDR32 r16, r25, r0
        ADDI32 r23, r0, SYS_CLOSE
        SYSCALL
        ADDR32 r16, r27, r0
        ADDI32 r23, r0, SYS_PUTDEC
        SYSCALL
        ADDI32 r16, r0, s_done
        JMP32 .say
.nocreate:
        ADDR32 r16, r26, r0
        ADDI32 r23, r0, SYS_CLOSE
        SYSCALL
        ADDI32 r16, r0, s_nocreate
        JMP32 .say
.nofile:
        ADDI32 r16, r0, s_nofile
        JMP32 .say
.usage: ADDI32 r16, r0, s_usage
.say:   ADDI32 r23, r0, SYS_PUTS
        SYSCALL
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

s_usage:    .asciz "Usage: TOUPPER source destination\n"
s_nofile:   .asciz "File not found\n"
s_nocreate: .asciz "File creation error\n"
s_done:     .asciz " bytes converted\n"
buf:        .reserve 256
