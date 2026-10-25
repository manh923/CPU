; mydos.asm — BIOS（ROM）＋ブートローダー＋張りぼての MyDOS
;
; 起動の流れ
;   1. BIOS：画面を消して見出し、メモリテスト
;   2. 1 秒待つ。U キーなら UART から起動（tools/mkboot.js で作ったものを送る）、ほかのキーか時間切れなら次へ
;   3. ブートローダー：ROM の中の MyDOS を RAM の 0x20000 に写して、そこへ飛ぶ
;   4. MyDOS：C:\> を出してコマンドを待つ（HELP で一覧）
;
; BIOS の機能は ROM の決まった番地から呼べる（UART から読み込んだプログラム用。下の「BIOS の入口」）。
; 呼び出し規約は 8 章どおり：引数・戻り値は r16〜、r16〜r23 は壊れてよい、r24〜r31 は保存する。

UART_TX     = 0x00010000
UART_STATUS = 0x00010004
UART_RX     = 0x00010008
TIMER_COUNT = 0x00010010
LED         = 0x00010020
VRAM        = 0x00018000
COLS        = 160
ROWS        = 45
OS_BASE     = 0x00020000                ; MyDOS を写す先（内蔵 RAM の先頭）
OS_MAX      = 0x7000                    ; 0x20000〜0x26FFF（28KB）まで
BDA         = 0x00027000                ; BIOS の変数（BIOS Data Area）
CUR_X       = BDA + 0                   ; カーソルの桁
CUR_Y       = BDA + 4                   ; カーソルの行
ATTR        = BDA + 8                   ; 文字の色
LAST_CR     = BDA + 12                  ; 直前の入力が \r だった（\r\n を 1 回の Enter にする）
STACK_TOP   = 0x00028000
WAIT_US     = 1000000                   ; U キーを待つ時間
MEMTEST_US  = 15000                     ; メモリテストで 1KB ごとに待つ時間（見た目のため）

; ==================================================================
; ROM（BIOS）
; ==================================================================
        .org 0
reset:  JMP32 bios_start

; ---- BIOS の入口（番地は固定。ほかのプログラムから CALL32 で呼ぶ） ----
        .org 0x10
        JMP32 bios_putc                 ; 0x10 putc(r16 = 文字)
        JMP32 bios_puts                 ; 0x18 puts(r16 = 文字列)
        JMP32 bios_getc                 ; 0x20 getc() → r16
        JMP32 bios_getline              ; 0x28 getline(r16 = 置き場所, r17 = 最大の長さ) → r16 = 長さ
        JMP32 bios_cls                  ; 0x30 cls()
        JMP32 bios_putdec               ; 0x38 putdec(r16 = 符号なしの数)
        JMP32 bios_puthex               ; 0x40 puthex(r16 = 数、16 進 8 桁)
        JMP32 reset                     ; 0x48 再起動

bios_start:
        ADDI32 sp, r0, STACK_TOP
        ADDI32 evec, r0, bios_trap
        ADDI32 r16, r0, 0x07
        STORE32_32 r16, r0, ATTR
        STORE32_32 r0, r0, LAST_CR
        STORE32_32 r0, r0, LED
        CALL32 bios_cls

        ADDI32 r16, r0, 0x0F            ; 明るい白
        STORE32_32 r16, r0, ATTR
        ADDI32 r16, r0, s_bios
        CALL32 bios_puts
        ADDI32 r16, r0, 0x07
        STORE32_32 r16, r0, ATTR
        ADDI32 r16, r0, s_cpu
        CALL32 bios_puts

        ; ---- メモリテスト ----
        ; 0x20000〜0x26FFF を 1KB ずつ書いて読み戻す。残りの 4KB は BIOS の変数とスタックで使っているので数えるだけ
        ADDI32 r24, r0, OS_BASE         ; 調べる番地
        ADDI32 r25, r0, 0               ; 済んだ KB 数
.kb:    ADDI32 r26, r24, 1024
        CMPGEUI32 p1, r24, BDA
        BR32 p1, .count
.word:  XORI32 r17, r24, 0x5A5AA5A5     ; 番地ごとに違う値を書いて読み戻す
        STORE32_32 r17, r24, 0
        LOAD32_32 r18, r24, 0
        CMPNER32 p1, r17, r18
        BR32 p1, .memfail
        ADDI32 r24, r24, 4
        CMPLTUR32 p1, r24, r26
        BR32 p1, .word
.count: ADDR32 r24, r26, r0
        ADDI32 r25, r25, 1
        ADDI32 r16, r0, 13              ; 行頭に戻って書き直す（画面も端末も）
        CALL32 bios_putc
        ADDI32 r16, r0, s_memtest
        CALL32 bios_puts
        ADDR32 r16, r25, r0
        CALL32 bios_putdec
        ADDI32 r16, r0, MEMTEST_US
        CALL32 delay
        CMPLTI32 p1, r25, 32
        BR32 p1, .kb
        ADDI32 r16, r0, s_kbok
        CALL32 bios_puts

        ADDI32 r16, r0, s_drives
        CALL32 bios_puts

        ; ---- 1 秒だけ U キーを待つ ----
        ADDI32 r16, r0, s_press
        CALL32 bios_puts
        LOAD32_32 r24, r0, TIMER_COUNT
.wait:  LOAD32_32 r16, r0, UART_STATUS
        ANDI32 r16, r16, 2
        CMPNEI32 p1, r16, 0
        BR32 p1, .key
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CMPLTUI32 p1, r16, WAIT_US
        BR32 p1, .wait
        JMP32 boot_rom
.key:   LOAD32_32 r16, r0, UART_RX
        ORI32 r16, r16, 0x20            ; 小文字にそろえる
        CMPEQI32 p1, r16, 'u'
        BR32 p1, boot_uart
        JMP32 boot_rom

.memfail:
        ADDI32 r16, r0, s_memfail
        CALL32 bios_puts
        ADDR32 r16, r24, r0
        CALL32 bios_puthex
        HLT

; ---- ブートローダー：ROM の MyDOS を RAM へ写して飛ぶ ----
boot_rom:
        ADDI32 r16, r0, s_starting
        CALL32 bios_puts
        ADDI32 r16, r0, os_image        ; 写す元（ROM）
        ADDI32 r17, r0, os_image_end
        ADDI32 r18, r0, OS_BASE         ; 写す先（RAM）
.copy:  LOAD32_32 r19, r16, 0
        STORE32_32 r19, r18, 0
        ADDI32 r16, r16, 4
        ADDI32 r18, r18, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .copy
        JMP32 OS_BASE

; ---- UART から起動：'M' 'C' 長さ（4 バイト、リトルエンディアン）中身 を受け取って 0x20000 へ ----
boot_uart:
        ADDI32 r16, r0, s_uartboot
        CALL32 bios_puts
.sync:  CALL32 uart_getc
        CMPNEI32 p1, r16, 'M'
        BR32 p1, .sync
.sync2: CALL32 uart_getc
        CMPEQI32 p1, r16, 'M'
        BR32 p1, .sync2
        CMPNEI32 p1, r16, 'C'
        BR32 p1, .sync
        ADDI32 r24, r0, 0               ; 長さ
        ADDI32 r25, r0, 0               ; 何 bit ずらすか
.len:   CALL32 uart_getc
        SHLR32 r16, r16, r25
        ORR32 r24, r24, r16
        ADDI32 r25, r25, 8
        CMPLTI32 p1, r25, 32
        BR32 p1, .len
        ADDI32 r16, r0, OS_MAX
        CMPLTUR32 p1, r16, r24          ; OS_MAX < 長さ なら大きすぎる
        BR32 p1, .toobig
        ADDI32 r25, r0, OS_BASE
        ADDR32 r26, r25, r24
.data:  CMPGEUR32 p1, r25, r26
        BR32 p1, .done
        CALL32 uart_getc
        STORE8_32 r16, r25, 0
        ADDI32 r25, r25, 1
        JMP32 .data
.done:  ADDI32 r16, r0, s_loaded
        CALL32 bios_puts
        ADDR32 r16, r24, r0
        CALL32 bios_putdec
        ADDI32 r16, r0, s_bytes
        CALL32 bios_puts
        ADDI32 sp, r0, STACK_TOP
        JMP32 OS_BASE
.toobig:
        ADDI32 r16, r0, s_toobig
        CALL32 bios_puts
        HLT

; ---- 例外が起きたら理由を出して止まる ----
bios_trap:
        ADDI32 sp, r0, STACK_TOP
        ADDI32 r16, r0, 0x4F            ; 赤地に白
        STORE32_32 r16, r0, ATTR
        ADDI32 r16, r0, s_trap1
        CALL32 bios_puts
        ADDR32 r16, cause, r0
        CALL32 bios_puthex
        ADDI32 r16, r0, s_trap2
        CALL32 bios_puts
        ADDR32 r16, epc, r0
        CALL32 bios_puthex
        ADDI32 r16, r0, s_trap3
        CALL32 bios_puts
        HLT

; ==================================================================
; BIOS の機能
; ==================================================================

; delay(r16 = µs)。r17, r18 を壊す
delay:
        LOAD32_32 r17, r0, TIMER_COUNT
.w:     LOAD32_32 r18, r0, TIMER_COUNT
        SUBR32 r18, r18, r17
        CMPLTUR32 p1, r18, r16
        BR32 p1, .w
        RET32

; uart_raw(r18 = 1 バイト)。r19 を壊す
uart_raw:
        LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p3, r19, 0
        BR32 p3, uart_raw
        STORE32_32 r18, r0, UART_TX
        RET32

; uart_putc(r16)：\n は \r\n、\b は "\b \b" にして送る。r16 は壊さない。r17〜r19 を壊す
uart_putc:
        ADDR32 r17, lr, r0
        CMPEQI32 p2, r16, 10
        BR32 p2, .lf
        CMPEQI32 p2, r16, 8
        BR32 p2, .bs
        ADDR32 r18, r16, r0
        CALL32 uart_raw
        JMPR32 r17
.lf:    ADDI32 r18, r0, 13
        CALL32 uart_raw
        ADDI32 r18, r0, 10
        CALL32 uart_raw
        JMPR32 r17
.bs:    ADDI32 r18, r0, 8
        CALL32 uart_raw
        ADDI32 r18, r0, ' '
        CALL32 uart_raw
        ADDI32 r18, r0, 8
        CALL32 uart_raw
        JMPR32 r17

; uart_getc() → r16：UART から 1 バイト（画面には何も出さない）
uart_getc:
        LOAD32_32 r16, r0, UART_STATUS
        ANDI32 r16, r16, 2
        CMPEQI32 p1, r16, 0
        BR32 p1, uart_getc
        LOAD32_32 r16, r0, UART_RX
        RET32

; cell_ptr() → r17：カーソルの位置の VRAM の番地。r18 を壊す
cell_ptr:
        LOAD32_32 r17, r0, CUR_Y
        MULI32 r17, r17, COLS
        LOAD32_32 r18, r0, CUR_X
        ADDR32 r17, r17, r18
        SHLI32 r17, r17, 1
        ADDI32 r17, r17, VRAM
        RET32

; blank() → r17：今の色の空白 2 文字分（32bit）。r18 を壊す
blank:
        LOAD32_32 r17, r0, ATTR
        SHLI32 r17, r17, 8
        ORI32 r17, r17, ' '
        SHLI32 r18, r17, 16
        ORR32 r17, r17, r18
        RET32

; cls()：画面を今の色で消して、カーソルを左上へ
bios_cls:
        ADDR32 r20, lr, r0
        CALL32 blank
        ADDI32 r16, r0, VRAM
        ADDI32 r18, r0, VRAM + COLS * ROWS * 2
.l:     STORE32_32 r17, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r18
        BR32 p1, .l
        STORE32_32 r0, r0, CUR_X
        STORE32_32 r0, r0, CUR_Y
        JMPR32 r20

; scroll()：画面を 1 行上へずらし、最後の行を消す
scroll:
        ADDR32 r20, lr, r0
        ADDI32 r16, r0, VRAM
        ADDI32 r17, r0, VRAM + (ROWS - 1) * COLS * 2
.c:     LOAD32_32 r18, r16, COLS * 2
        STORE32_32 r18, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .c
        CALL32 blank
        ADDI32 r19, r0, VRAM + ROWS * COLS * 2
.f:     STORE32_32 r17, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r19
        BR32 p1, .f
        JMPR32 r20

; putc(r16)：画面と UART に 1 文字。\n 改行、\r 行頭へ、\b 1 文字戻して消す
bios_putc:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        CALL32 uart_putc
        CMPEQI32 p1, r24, 10
        BR32 p1, .nl
        CMPEQI32 p1, r24, 13
        BR32 p1, .cr
        CMPEQI32 p1, r24, 8
        BR32 p1, .bs
        CALL32 cell_ptr
        LOAD32_32 r18, r0, ATTR
        SHLI32 r18, r18, 8
        ORR32 r18, r18, r24
        STORE16_32 r18, r17, 0
        LOAD32_32 r17, r0, CUR_X
        ADDI32 r17, r17, 1
        STORE32_32 r17, r0, CUR_X
        CMPLTI32 p1, r17, COLS
        BR32 p1, .done
.nl:    STORE32_32 r0, r0, CUR_X
        LOAD32_32 r17, r0, CUR_Y
        ADDI32 r17, r17, 1
        CMPLTI32 p1, r17, ROWS
        BR32 p1, .sety
        CALL32 scroll
        ADDI32 r17, r0, ROWS - 1
.sety:  STORE32_32 r17, r0, CUR_Y
        JMP32 .done
.cr:    STORE32_32 r0, r0, CUR_X
        JMP32 .done
.bs:    LOAD32_32 r17, r0, CUR_X
        CMPEQI32 p1, r17, 0
        BR32 p1, .done
        ADDI32 r17, r17, -1
        STORE32_32 r17, r0, CUR_X
        CALL32 cell_ptr
        LOAD32_32 r18, r0, ATTR
        SHLI32 r18, r18, 8
        ORI32 r18, r18, ' '
        STORE16_32 r18, r17, 0
.done:  LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; puts(r16)：0 終わりの文字列
bios_puts:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r25, sp, 4
        ADDR32 r25, r16, r0
.n:     LOAD8U_32 r16, r25, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .e
        CALL32 bios_putc
        ADDI32 r25, r25, 1
        JMP32 .n
.e:     LOAD32_32 lr, sp, 0
        LOAD32_32 r25, sp, 4
        ADDI32 sp, sp, 8
        RET32

; putdec(r16)：符号なし 10 進。数字をスタックに積んで逆順に出す
bios_putdec:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, sp, r0
        ADDR32 r25, r16, r0
.d:     REMUI32 r17, r25, 10
        DIVUI32 r25, r25, 10
        ADDI32 r17, r17, '0'
        ADDI32 sp, sp, -8
        STORE32_32 r17, sp, 0
        CMPNEI32 p1, r25, 0
        BR32 p1, .d
.o:     LOAD32_32 r16, sp, 0
        ADDI32 sp, sp, 8
        CALL32 bios_putc
        CMPNER32 p1, sp, r24
        BR32 p1, .o
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; puthex(r16)：16 進 8 桁
bios_puthex:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r16, r0
        ADDI32 r25, r0, 8
.h:     SHRI32 r16, r24, 28
        CMPLTUI32 p1, r16, 10
        ADDI32 r17, r16, '0'
        ADDI32 r18, r16, 'A' - 10
        SEL32 r16, r17, r18, p1         ; 0〜9 なら数字、10〜15 なら A〜F
        CALL32 bios_putc
        SHLI32 r24, r24, 4
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, .h
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; getc() → r16：キーが来るまでカーソルを点滅させて待つ
bios_getc:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        CALL32 cell_ptr
        ADDR32 r24, r17, r0
.w:     LOAD32_32 r16, r0, UART_STATUS
        ANDI32 r16, r16, 2
        CMPNEI32 p1, r16, 0
        BR32 p1, .got
        LOAD32_32 r16, r0, TIMER_COUNT  ; 約 0.26 秒ごとに '_' と空白を入れ替える
        SHRI32 r16, r16, 18
        ANDI32 r16, r16, 1
        CMPNEI32 p1, r16, 0
        LOAD32_32 r17, r0, ATTR
        SHLI32 r17, r17, 8
        ADDI32 r18, r17, '_'
        ORI32 r17, r17, ' '
        SEL32 r17, r18, r17, p1
        STORE16_32 r17, r24, 0
        JMP32 .w
.got:   LOAD32_32 r17, r0, ATTR
        SHLI32 r17, r17, 8
        ORI32 r17, r17, ' '
        STORE16_32 r17, r24, 0
        LOAD32_32 r16, r0, UART_RX
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; getline(r16 = 置き場所, r17 = 最大の長さ) → r16 = 長さ。Enter で終わり、Backspace で消す
bios_getline:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDR32 r24, r16, r0
        ADDR32 r25, r17, r0
        ADDI32 r26, r0, 0
.k:     CALL32 bios_getc
        LOAD32_32 r17, r0, LAST_CR
        STORE32_32 r0, r0, LAST_CR
        CMPEQI32 p1, r16, 13
        BR32 p1, .cr
        CMPEQI32 p1, r16, 10
        BR32 p1, .lf
        CMPEQI32 p1, r16, 8
        BR32 p1, .bs
        CMPEQI32 p1, r16, 127
        BR32 p1, .bs
        CMPLTUI32 p1, r16, 32           ; ほかの制御文字は無視
        BR32 p1, .k
        CMPGER32 p1, r26, r25           ; いっぱいなら無視
        BR32 p1, .k
        ADDR32 r17, r24, r26
        STORE8_32 r16, r17, 0
        ADDI32 r26, r26, 1
        CALL32 bios_putc
        JMP32 .k
.bs:    CMPEQI32 p1, r26, 0
        BR32 p1, .k
        ADDI32 r26, r26, -1
        ADDI32 r16, r0, 8
        CALL32 bios_putc
        JMP32 .k
.lf:    CMPNEI32 p1, r17, 0             ; \r の直後の \n は無視
        BR32 p1, .k
        JMP32 .enter
.cr:    ADDI32 r16, r0, 1
        STORE32_32 r16, r0, LAST_CR
.enter: ADDR32 r17, r24, r26
        STORE8_32 r0, r17, 0
        ADDI32 r16, r0, 10
        CALL32 bios_putc
        ADDR32 r16, r26, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

s_bios:     .asciz "MyCPU BIOS Version 1.00   (C) 2026 MyCPU Project\n\n"
s_cpu:      .asciz "CPU         : MyCPU-32 @ 27MHz\n"
s_memtest:  .asciz "Memory Test : "
s_kbok:     .asciz " KB OK\n"
s_memfail:  .asciz " FAILED at 0x"
s_drives:   .asciz "Drive C:    : MYDOS.SYS (ROM disk)\n\n"
s_press:    .asciz "Press U for UART boot...\n"
s_starting: .asciz "Starting MyDOS...\n\n"
s_uartboot: .asciz "UART boot: send 'MC' + length (4 bytes, little endian) + image\n"
s_loaded:   .asciz "Loaded "
s_bytes:    .asciz " bytes. Jumping to 0x00020000\n\n"
s_toobig:   .asciz "Image too large (max 28672 bytes). System halted.\n"
s_trap1:    .asciz "\n *** EXCEPTION  CAUSE="
s_trap2:    .asciz "  EPC="
s_trap3:    .asciz "  System halted. *** \n"

; ==================================================================
; MyDOS（ROM に置き、0x20000 に写して動かす）
; ==================================================================
        .align 16
os_image:
        .phase OS_BASE

os_start:
        ADDI32 sp, r0, STACK_TOP
        ADDI32 r16, r0, s_banner
        CALL32 bios_puts

shell:
        ADDI32 r16, r0, s_prompt
        CALL32 bios_puts
        ADDI32 r16, r0, linebuf
        ADDI32 r17, r0, 72
        CALL32 bios_getline
        CALL32 parse
        LOAD8U_32 r16, r0, cmdbuf
        CMPEQI32 p1, r16, 0             ; 何も打たずに Enter
        BR32 p1, shell
        ADDI32 r24, r0, commands
.find:  LOAD32_32 r16, r24, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .bad
        ADDI32 r17, r0, cmdbuf
        CALL32 streq
        CMPNEI32 p1, r16, 0
        BR32 p1, .run
        ADDI32 r24, r24, 8
        JMP32 .find
.run:   LOAD32_32 r16, r24, 4
        CALLR32 r16
        JMP32 shell
.bad:   ADDI32 r16, r0, s_bad
        CALL32 bios_puts
        JMP32 shell

; parse()：linebuf の最初の語を大文字にして cmdbuf へ。args ← 残りの先頭（空白を飛ばしたところ）
parse:
        ADDI32 r16, r0, linebuf
.sp:    LOAD8U_32 r17, r16, 0
        CMPNEI32 p1, r17, ' '
        BR32 p1, .word
        ADDI32 r16, r16, 1
        JMP32 .sp
.word:  ADDI32 r18, r0, cmdbuf
.w:     LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
        CMPEQI32 p1, r17, ' '
        BR32 p1, .end
        ADDI32 r19, r17, -'a'           ; 'a'〜'z' なら 32 引いて大文字に
        CMPLTUI32 p1, r19, 26
        ADDI32 r19, r17, -32
        SEL32 r17, r19, r17, p1
        STORE8_32 r17, r18, 0
        ADDI32 r16, r16, 1
        ADDI32 r18, r18, 1
        JMP32 .w
.end:   STORE8_32 r0, r18, 0
.a:     LOAD8U_32 r17, r16, 0
        CMPNEI32 p1, r17, ' '
        BR32 p1, .done
        ADDI32 r16, r16, 1
        JMP32 .a
.done:  STORE32_32 r16, r0, args
        RET32

; upcase(r16)：文字列をその場で大文字に。r17〜r19 を壊す
upcase:
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .e
        ADDI32 r19, r17, -'a'
        CMPLTUI32 p1, r19, 26
        ADDI32 r19, r17, -32
        SEL32 r17, r19, r17, p1
        STORE8_32 r17, r16, 0
        ADDI32 r16, r16, 1
        JMP32 upcase
.e:     RET32

; streq(r16, r17) → r16 = 同じなら 1。r18, r19 を壊す
streq:
        LOAD8U_32 r18, r16, 0
        LOAD8U_32 r19, r17, 0
        CMPNER32 p1, r18, r19
        BR32 p1, .ne
        CMPEQI32 p1, r18, 0
        BR32 p1, .eq
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 1
        JMP32 streq
.ne:    ADDI32 r16, r0, 0
        RET32
.eq:    ADDI32 r16, r0, 1
        RET32

; hex2(r16 = 文字列) → r16 = 16 進 2 桁の値（読めなければ −1）。r17〜r20 を壊す
hex2:
        ADDI32 r19, r0, 0
        ADDI32 r18, r16, 2
.d:     LOAD8U_32 r17, r16, 0
        ORI32 r17, r17, 0x20            ; 英字を小文字に（数字は変わらない）
        ADDI32 r20, r17, -'0'
        CMPLTUI32 p1, r20, 10
        BR32 p1, .ok
        ADDI32 r20, r17, -'a'
        CMPLTUI32 p1, r20, 6
        BR32 p1, .af
        ADDI32 r16, r0, -1
        RET32
.af:    ADDI32 r20, r20, 10
.ok:    SHLI32 r19, r19, 4
        ORR32 r19, r19, r20
        ADDI32 r16, r16, 1
        CMPNER32 p1, r16, r18
        BR32 p1, .d
        LOAD8U_32 r17, r16, 0           ; 3 文字目があったら読めない扱い
        CMPNEI32 p1, r17, 0
        ADDI32 r16, r0, -1
        SEL32 r16, r16, r19, p1
        RET32

; ---- コマンド ----
commands:
        .word c_help, cmd_help
        .word c_ver, cmd_ver
        .word c_dir, cmd_dir
        .word c_type, cmd_type
        .word c_cls, cmd_cls
        .word c_echo, cmd_echo
        .word c_mem, cmd_mem
        .word c_time, cmd_time
        .word c_color, cmd_color
        .word c_led, cmd_led
        .word c_hello, cmd_hello
        .word c_reboot, cmd_reboot
        .word c_shutdown, cmd_shutdown
        .word 0, 0

cmd_help:
        ADDI32 r16, r0, s_help
        JMP32 bios_puts
cmd_ver:
        ADDI32 r16, r0, s_ver
        JMP32 bios_puts
cmd_dir:
        ADDI32 r16, r0, s_dir
        JMP32 bios_puts
cmd_cls:
        JMP32 bios_cls
cmd_hello:
        ADDI32 r16, r0, s_hello
        JMP32 bios_puts
cmd_reboot:
        JMP32 reset

cmd_echo:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD32_32 r16, r0, args
        CALL32 bios_puts
        ADDI32 r16, r0, s_nl2
        CALL32 bios_puts
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

cmd_type:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD32_32 r16, r0, args
        LOAD8U_32 r17, r16, 0
        ADDI32 r18, r0, s_missing
        CMPEQI32 p1, r17, 0
        BR32 p1, .say
        CALL32 upcase
        LOAD32_32 r16, r0, args
        ADDI32 r17, r0, f_readme
        CALL32 streq
        ADDI32 r18, r0, s_readme
        CMPNEI32 p1, r16, 0
        BR32 p1, .say
        LOAD32_32 r16, r0, args
        ADDI32 r17, r0, f_hello
        CALL32 streq
        ADDI32 r18, r0, s_binary
        CMPNEI32 p1, r16, 0
        BR32 p1, .say
        ADDI32 r18, r0, s_notfound
.say:   ADDR32 r16, r18, r0
        CALL32 bios_puts
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

cmd_mem:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        ADDI32 r16, r0, s_mem1
        CALL32 bios_puts
        ADDI32 r16, r0, BDA - os_end    ; MyDOS の後ろから BIOS の変数の手前まで
        CALL32 bios_putdec
        ADDI32 r16, r0, s_mem2
        CALL32 bios_puts
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; TIME：起動してからの時間（タイマーは 1µs ごとに増える）
cmd_time:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDI32 r16, r0, s_uptime
        CALL32 bios_puts
        LOAD32_32 r24, r0, TIMER_COUNT
        DIVUI32 r16, r24, 1000000
        CALL32 bios_putdec
        ADDI32 r16, r0, '.'
        CALL32 bios_putc
        DIVUI32 r24, r24, 1000          ; ミリ秒を 3 桁で
        REMUI32 r24, r24, 1000
        DIVUI32 r16, r24, 100
        ADDI32 r16, r16, '0'
        CALL32 bios_putc
        DIVUI32 r16, r24, 10
        REMUI32 r16, r16, 10
        ADDI32 r16, r16, '0'
        CALL32 bios_putc
        REMUI32 r16, r24, 10
        ADDI32 r16, r16, '0'
        CALL32 bios_putc
        ADDI32 r16, r0, s_sec
        CALL32 bios_puts
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; COLOR xy：x = 背景色、y = 文字色（16 進）。画面全体の色を変える。引数なしで 07 に戻す
cmd_color:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD32_32 r16, r0, args
        LOAD8U_32 r17, r16, 0
        ADDI32 r16, r0, 0x07
        CMPEQI32 p1, r17, 0
        BR32 p1, .set
        LOAD32_32 r16, r0, args
        CALL32 hex2
        CMPLTI32 p1, r16, 0
        BR32 p1, .usage
.set:   STORE32_32 r16, r0, ATTR
        ADDI32 r17, r0, VRAM + 1        ; 色のバイトだけ全部書き換える
        ADDI32 r18, r0, VRAM + COLS * ROWS * 2
.l:     STORE8_32 r16, r17, 0
        ADDI32 r17, r17, 2
        CMPLTUR32 p1, r17, r18
        BR32 p1, .l
        ADDI32 r16, r0, 10
        CALL32 bios_putc
        JMP32 .ret
.usage: ADDI32 r16, r0, s_color_usage
        CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; LED xx：基板の LED（16 進 2 桁、下位 6bit）
cmd_led:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD32_32 r16, r0, args
        CALL32 hex2
        CMPLTI32 p1, r16, 0
        BR32 p1, .usage
        STORE32_32 r16, r0, LED
        ADDI32 r16, r0, 10
        CALL32 bios_putc
        JMP32 .ret
.usage: ADDI32 r16, r0, s_led_usage
        CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

cmd_shutdown:
        ADDI32 r16, r0, 0x0E            ; 黒地に黄色
        STORE32_32 r16, r0, ATTR
        CALL32 bios_cls
        ADDI32 r16, r0, s_safe
        CALL32 bios_puts
        HLT

s_banner:   .asciz "MyDOS Version 1.0\n(C)Copyright MyCPU Project 2026.\nType HELP for a list of commands.\n\n"
s_prompt:   .asciz "C:\\>"
s_bad:      .asciz "Bad command or file name\n\n"
s_ver:      .asciz "\nMyDOS Version 1.0 (MyCPU-32)\n\n"
s_help:     .ascii "CLS       Clears the screen.\n"
            .ascii "COLOR xy  Sets colors (x = background, y = text, hex). COLOR alone resets.\n"
            .ascii "DIR       Displays a list of files.\n"
            .ascii "ECHO      Displays a message.\n"
            .ascii "HELLO     Runs HELLO.EXE.\n"
            .ascii "LED xx    Turns the board LEDs on/off (hex).\n"
            .ascii "MEM       Displays the amount of free memory.\n"
            .ascii "REBOOT    Restarts the computer.\n"
            .ascii "SHUTDOWN  Halts the CPU.\n"
            .ascii "TIME      Displays the time since boot.\n"
            .ascii "TYPE      Displays the contents of a text file.\n"
            .asciz "VER       Displays the MyDOS version.\n\n"
s_dir:      .ascii "\n Volume in drive C is MYCPU\n"
            .ascii " Volume Serial Number is 2026-1025\n"
            .ascii " Directory of C:\\\n\n"
            .ascii "COMMAND  COM      4096  10-25-26  12:00a\n"
            .ascii "README   TXT       318  10-25-26  12:00a\n"
            .ascii "HELLO    EXE      1024  10-25-26  12:00a\n"
            .ascii "        3 file(s)         5438 bytes\n"
            .asciz "                         0 bytes free\n\n"
s_readme:   .ascii "MyCPU README\n"
            .ascii "============\n"
            .ascii "This computer runs on a homemade CPU with a homemade instruction set.\n"
            .ascii "32/64-bit, no flags, 1-bit predicate registers, little endian.\n"
            .ascii "The \"disk\" is a ROM. Nothing you do here is saved. Have fun.\n\n"
            .asciz "Load your own program: reboot, press U, and send a file made by tools/mkboot.js.\n\n"
s_binary:   .asciz "MZ\x90\x03\x01\x04\xff\xff\x0b\x02\x01  (it's a program, not text)\n\n"
s_notfound: .asciz "File not found\n\n"
s_missing:  .asciz "Required parameter missing\n\n"
s_hello:    .asciz "Hello, World!\n\n"
s_nl2:      .asciz "\n\n"
s_mem1:     .asciz "\n    32768 bytes total memory\n    "
s_mem2:     .asciz " bytes free\n\n"
s_uptime:   .asciz "Uptime: "
s_sec:      .asciz " seconds\n\n"
s_color_usage: .asciz "Usage: COLOR xy  (x = background, y = text, 0-F)\n\n"
s_led_usage:   .asciz "Usage: LED xx  (hex, lower 6 bits)\n\n"
s_safe:     .asciz "\n\n          It's now safe to turn off your computer.\n"
c_help:     .asciz "HELP"
c_ver:      .asciz "VER"
c_dir:      .asciz "DIR"
c_type:     .asciz "TYPE"
c_cls:      .asciz "CLS"
c_echo:     .asciz "ECHO"
c_mem:      .asciz "MEM"
c_time:     .asciz "TIME"
c_color:    .asciz "COLOR"
c_led:      .asciz "LED"
c_hello:    .asciz "HELLO"
c_reboot:   .asciz "REBOOT"
c_shutdown: .asciz "SHUTDOWN"
f_readme:   .asciz "README.TXT"
f_hello:    .asciz "HELLO.EXE"
        .align 4
args:       .word 0
linebuf:    .space 80
cmdbuf:     .space 80
        .align 16
os_end:
        .dephase
os_image_end:
