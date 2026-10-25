; hello_uart.asm — UART から読み込んで動かすプログラムの例
; mydos.asm の BIOS で U キーを押し、次で作ったファイルを送ると、0x20000 に置かれて動く。
;   node tools/mkboot.js examples/uartboot/hello_uart.asm -o hello_uart.boot
; 画面や入力は BIOS の入口（ROM の決まった番地）を CALL32 して使う。
BIOS_PUTC   = 0x10
BIOS_PUTS   = 0x18
BIOS_GETC   = 0x20
BIOS_PUTDEC = 0x38
BIOS_REBOOT = 0x48

        .org 0x20000
start:
        ADDI32 r16, r0, msg
        CALL32 BIOS_PUTS
        ADDI32 r24, r0, 1               ; 1〜10 の 2 乗を並べる
.loop:  MULR32 r16, r24, r24
        CALL32 BIOS_PUTDEC
        ADDI32 r16, r0, ' '
        CALL32 BIOS_PUTC
        ADDI32 r24, r24, 1
        CMPLTI32 p1, r24, 11
        BR32 p1, .loop
        ADDI32 r16, r0, msg2
        CALL32 BIOS_PUTS
        CALL32 BIOS_GETC
        JMP32 BIOS_REBOOT

msg:    .asciz "Hello from a program loaded over UART!\n"
msg2:   .asciz "\nPress any key to reboot.\n"
