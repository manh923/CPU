; bios.asm — ROM の BIOS
;
; 起動の流れ
;   1. 画面を消して見出し、メモリテスト、SD カードの初期化
;   2. 1 秒待つ。U キーなら UART から起動（tools/mkboot.js で作ったものを送る）
;   3. SD カードの FAT（FAT16 / FAT32）のルートディレクトリから MYDOS.SYS を探し、0x20000 に読み込んで飛ぶ
;      見つからなければ "Non-System disk or disk error" を出して、キーを待ってやり直す
;
; BIOS の呼び方は 2 つ
;   ・ROM の決まった番地（下の「BIOS の入口」）を CALL32 する。MyDOS のようにカーネルモードで動くもの用
;   ・SYSCALL（x86 の INT にあたる）：r23 に機能番号を入れて SYSCALL すると、RAM の表 VEC（0x2B100）の
;     その番号の番地が呼ばれる。表は RAM にあるので、あとから書き換えて機能を差し替えられる。
;     BIOS は画面・キーの機能（1〜10）を登録する。MyDOS がファイルの機能などを足し、画面出力を差し替える
; ユーザーモードのプログラムが例外を起こしたら、USER_FAULT（BIOS の変数）に番地があればそこへ飛ぶ。
; 呼び出し規約は 8 章どおり：引数・戻り値は r16〜、r16〜r23 は壊れてよい、r24〜r31 は保存する。

UART_TX     = 0x00010000
UART_STATUS = 0x00010004
UART_RX     = 0x00010008
TIMER_COUNT = 0x00010010
LED         = 0x00010020
VRAM        = 0x00018000
COLS        = 160
ROWS        = 45
OS_BASE     = 0x00020000                ; MYDOS.SYS・UART 起動のプログラムを置く場所（内蔵 RAM の先頭）
OS_MAX      = 0xB000                    ; UART 起動で読み込めるのは 0x20000〜0x2AFFF（44KB）まで
SYS_MAX     = 0x6000                    ; MYDOS.SYS は 24KB まで（0x26000 からはプログラム用）
SD_DATA     = 0x00010030                ; SPI：書くと 1 バイト送り、読むと受け取った 1 バイト
SD_CTRL     = 0x00010034                ; bit0 = CS（1 で選ぶ）、bit15〜8 = SCK の分周
SD_STATUS   = 0x00010038                ; bit0 = 送受信中
SD_SLOW     = 33 << 8                   ; SCK = 27MHz ÷ (2 × 34) ≒ 400kHz（初期化はこれ以下で）
SD_FAST     = 0 << 8                    ; SCK = 27MHz ÷ 2 = 13.5MHz
VEC         = 0x0002B100                ; SYSCALL の表（4 バイト × 64）
NVEC        = 64
SECBUF      = 0x0002B200                ; セクタ 1 つ分の置き場（512 バイト）
FATBUF      = 0x0002B400                ; FAT を読む置き場（512 バイト）
BDA         = 0x0002B000                ; BIOS の変数（BIOS Data Area）
CUR_X       = BDA + 0                   ; カーソルの桁
CUR_Y       = BDA + 4                   ; カーソルの行
ATTR        = BDA + 8                   ; 文字の色
LAST_CR     = BDA + 12                  ; 直前の入力が \r だった（\r\n を 1 回の Enter にする）
SD_TYPE     = BDA + 16                  ; SD カードの種類（0 = なし、1 = SDSC v1、2 = SDSC v2、3 = SDHC/SDXC）
SD_CTRLV    = BDA + 20                  ; SD_CTRL に書く分周（CS は bit0 で足す）
USER_FAULT  = BDA + 24                  ; ユーザーモードの例外を受け取る番地（0 なら止まる）
B_SPC       = BDA + 32                  ; ここから下はブートローダーの作業用
B_FAT       = BDA + 36
B_ROOT      = BDA + 40
B_RSECS     = BDA + 44
B_DATA      = BDA + 48
B_TYPE      = BDA + 52
B_RCLUS     = BDA + 56
STACK_TOP   = 0x0002C000
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
        JMP32 bios_putg                 ; 0x50 putg(r16 = 文字)：制御文字も字の形のまま画面に出す
        JMP32 bios_sd_init              ; 0x58 sd_init() → r16 = SD カードの種類（0 = なし）
        JMP32 bios_sd_read              ; 0x60 sd_read(r16 = セクタ番号, r17 = 置き場所 512 バイト) → r16 = 0 なら成功
        JMP32 bios_sd_write             ; 0x68 sd_write(r16 = セクタ番号, r17 = 512 バイト) → r16 = 0 なら成功
        JMP32 bios_kbhit                ; 0x70 kbhit() → r16 = キーが来ていれば 1
        JMP32 bios_setattr              ; 0x78 setattr(r16 = 色) → r16 = 前の色

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
        ; 0x20000〜0x2AFFF を 1KB ずつ書いて読み戻す。残りの 4KB は BIOS の変数とスタックで使っているので数えるだけ
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
        CMPLTI32 p1, r25, 48
        BR32 p1, .kb
        ADDI32 r16, r0, s_kbok
        CALL32 bios_puts

        ; ---- SD カード ----
        ADDI32 r16, r0, s_sd
        CALL32 bios_puts
        CALL32 bios_sd_init
        SHLI32 r16, r16, 2
        LOAD32_32 r16, r16, sd_names
        CALL32 bios_puts

        ; ---- SYSCALL の表：全部 0 にして、BIOS の機能を登録 ----
        ADDI32 r16, r0, VEC
        ADDI32 r17, r0, VEC + NVEC * 4
.vclr:  STORE32_32 r0, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .vclr
        ADDI32 r16, r0, bios_vectors
.vset:  LOAD32_32 r17, r16, 0
        CMPLTI32 p1, r17, 0
        BR32 p1, .vdone
        LOAD32_32 r18, r16, 4
        SHLI32 r17, r17, 2
        STORE32_32 r18, r17, VEC
        ADDI32 r16, r16, 8
        JMP32 .vset
.vdone: STORE32_32 r0, r0, USER_FAULT

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
        JMP32 boot_disk
.key:   LOAD32_32 r16, r0, UART_RX
        ORI32 r16, r16, 0x20            ; 小文字にそろえる
        CMPEQI32 p1, r16, 'u'
        BR32 p1, boot_uart
        JMP32 boot_disk

.memfail:
        ADDI32 r16, r0, s_memfail
        CALL32 bios_puts
        ADDR32 r16, r24, r0
        CALL32 bios_puthex
        HLT

; ---- SD カードから起動：MYDOS.SYS を 0x20000 に読み込んで飛ぶ ----
boot_disk:
        CALL32 load_sys
        CMPEQI32 p1, r16, 0
        BR32 p1, .nosys
        ADDI32 r16, r0, s_starting
        CALL32 bios_puts
        ADDI32 sp, r0, STACK_TOP
        JMP32 OS_BASE
.nosys: ADDI32 r16, r0, s_nonsys
        CALL32 bios_puts
        CALL32 bios_getc
        ORI32 r16, r16, 0x20
        CMPEQI32 p1, r16, 'u'
        BR32 p1, boot_uart
        CALL32 bios_sd_init             ; 挿し直したかもしれないので、カードを初期化し直す
        JMP32 boot_disk

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

; ---- 例外 ----
; SYSCALL：r23 の番号の番地を、r16〜r19 を引数にして呼ぶ。戻り値は r16・r17。LR は元に戻す
; ユーザーモードのプログラムの例外：USER_FAULT に番地があればそこへ（MyDOS がプログラムを終わらせる）
; それ以外：理由を出して止まる
bios_trap:
        CMPNEI32 p7, cause, 3
        BR32 p7, .fault
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 epc, sp, 4           ; 呼んだ機能の中で例外が起きても戻れるように
        STORE32_32 status, sp, 8
        CMPGEUI32 p7, r23, NVEC
        BR32 p7, .badfn
        SHLI32 r20, r23, 2
        LOAD32_32 r20, r20, VEC
        CMPEQI32 p7, r20, 0
        BR32 p7, .badfn
        CALLR32 r20
        JMP32 .sret
.badfn: ADDI32 r16, r0, -1
.sret:  LOAD32_32 lr, sp, 0
        LOAD32_32 epc, sp, 4
        LOAD32_32 status, sp, 8
        ADDI32 sp, sp, 16
        ADDI32 epc, epc, 4              ; SYSCALL の次へ戻る（6.1）
        ERET
.fault: ADDR32 r20, status, r0          ; 例外の直前がユーザーモードなら
        ANDI32 r20, r20, 4
        CMPEQI32 p7, r20, 0
        BR32 p7, .fatal
        LOAD32_32 r20, r0, USER_FAULT
        CMPEQI32 p7, r20, 0
        BR32 p7, .fatal
        JMPR32 r20
.fatal: ADDI32 sp, r0, STACK_TOP
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

        .align 4
bios_vectors:                           ; BIOS が SYSCALL の表に登録する機能（番号, 番地）
        .word 1, bios_putc
        .word 2, bios_puts
        .word 3, bios_getc
        .word 4, bios_getline
        .word 5, bios_cls
        .word 6, bios_putdec
        .word 7, bios_puthex
        .word 8, bios_putg
        .word 9, bios_setattr
        .word 10, bios_kbhit
        .word -1

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
.glyph: CALL32 cell_ptr
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

; putg(r16)：文字の形をそのまま画面に出す（☺ などの制御文字の形も）。UART へは表示できる文字だけ、ほかは '.'
bios_putg:
        ADDI32 sp, sp, -8               ; bios_putc と同じ形に積んでから、その途中へ入る
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        ADDI32 r18, r16, -32
        CMPLTUI32 p1, r18, 95           ; 0x20〜0x7E
        ADDI32 r18, r0, '.'
        SEL32 r18, r24, r18, p1
        CALL32 uart_raw
        JMP32 bios_putc.glyph

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

; ==================================================================
; SD カード（SPI モード）
; ==================================================================

; spi(r16 = 送る 1 バイト) → r16 = 受け取った 1 バイト。r17 を壊す
spi:
        STORE32_32 r16, r0, SD_DATA
.w:     LOAD32_32 r17, r0, SD_STATUS
        ANDI32 r17, r17, 1
        CMPNEI32 p4, r17, 0
        BR32 p4, .w
        LOAD32_32 r16, r0, SD_DATA
        RET32

; sd_cs(r16 = 1 で選ぶ、0 で離す)。r17 を壊す
sd_cs:
        LOAD32_32 r17, r0, SD_CTRLV
        ORR32 r17, r17, r16
        STORE32_32 r17, r0, SD_CTRL
        RET32

; sd_cmd(r16 = コマンド番号, r17 = 引数, r18 = CRC) → r16 = R1 応答（来なければ 0xFF）
sd_cmd:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDR32 r24, r16, r0
        ADDR32 r25, r17, r0
        ADDR32 r26, r18, r0
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ORI32 r16, r24, 0x40
        CALL32 spi
        SHRI32 r16, r25, 24
        CALL32 spi
        SHRI32 r16, r25, 16
        CALL32 spi
        SHRI32 r16, r25, 8
        CALL32 spi
        ADDR32 r16, r25, r0
        CALL32 spi
        ADDR32 r16, r26, r0
        CALL32 spi
        ADDI32 r24, r0, 10              ; 応答（bit7 が 0）を最大 10 バイト待つ
.r:     ADDI32 r16, r0, 0xFF
        CALL32 spi
        ANDI32 r17, r16, 0x80
        CMPEQI32 p1, r17, 0
        BR32 p1, .done
        ADDI32 r24, r24, -1
        CMPNEI32 p1, r24, 0
        BR32 p1, .r
.done:  LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; sd_init() → r16 = 種類（0 = なし・失敗、1 = SDSC v1、2 = SDSC v2、3 = SDHC/SDXC）
bios_sd_init:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r0, r0, SD_TYPE
        ADDI32 r16, r0, SD_SLOW
        STORE32_32 r16, r0, SD_CTRLV
        ADDI32 r16, r0, 0               ; CS を離したまま 80 クロック以上送る
        CALL32 sd_cs
        ADDI32 r24, r0, 10
.pre:   ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r24, r24, -1
        CMPNEI32 p1, r24, 0
        BR32 p1, .pre
        ADDI32 r16, r0, 1
        CALL32 sd_cs
        ADDI32 r24, r0, 10              ; CMD0（リセット）。アイドル（R1 = 1）になるまで最大 10 回
.c0:    ADDI32 r16, r0, 0
        ADDI32 r17, r0, 0
        ADDI32 r18, r0, 0x95
        CALL32 sd_cmd
        CMPEQI32 p1, r16, 1
        BR32 p1, .c8
        ADDI32 r24, r24, -1
        CMPNEI32 p1, r24, 0
        BR32 p1, .c0
        JMP32 .fail
.c8:    ADDI32 r16, r0, 8               ; CMD8（電圧の確認）。答えれば v2 カード
        ADDI32 r17, r0, 0x1AA
        ADDI32 r18, r0, 0x87
        CALL32 sd_cmd
        ADDI32 r25, r0, 0               ; r25 = v2 なら 1
        CMPNEI32 p1, r16, 1
        BR32 p1, .v1
        ADDI32 r24, r0, 4               ; 残り 4 バイト。最後が 0xAA なら正しい
.r7:    ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r24, r24, -1
        CMPNEI32 p1, r24, 0
        BR32 p1, .r7
        CMPNEI32 p1, r16, 0xAA
        BR32 p1, .fail
        ADDI32 r25, r0, 1
        JMP32 .acmd
.v1:    ANDI32 r16, r16, 0x04           ; 「知らないコマンド」なら v1 カード
        CMPEQI32 p1, r16, 0
        BR32 p1, .fail
.acmd:  LOAD32_32 r26, r0, TIMER_COUNT  ; ACMD41（初期化）を、終わるまで最大 1 秒繰り返す
.a41:   ADDI32 r16, r0, 55
        ADDI32 r17, r0, 0
        ADDI32 r18, r0, 0x65
        CALL32 sd_cmd
        ADDI32 r16, r0, 41
        SHLI32 r17, r25, 30             ; v2 なら HCS（大容量に対応している）を立てる
        ADDI32 r18, r0, 0x77
        CALL32 sd_cmd
        CMPEQI32 p1, r16, 0
        BR32 p1, .ready
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r26
        CMPLTUI32 p1, r16, 1000000
        BR32 p1, .a41
        JMP32 .fail
.ready: ADDI32 r24, r0, 1               ; v1 なら SDSC
        CMPEQI32 p1, r25, 0
        BR32 p1, .blen
        ADDI32 r16, r0, 58              ; CMD58（OCR）。CCS（bit30）が立っていれば SDHC/SDXC
        ADDI32 r17, r0, 0
        ADDI32 r18, r0, 0xFD
        CALL32 sd_cmd
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDR32 r26, r16, r0
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r24, r0, 2
        ANDI32 r26, r26, 0x40
        CMPEQI32 p1, r26, 0
        BR32 p1, .blen
        ADDI32 r24, r0, 3
        JMP32 .ok
.blen:  ADDI32 r16, r0, 16              ; SDSC はブロックの長さを 512 にしておく
        ADDI32 r17, r0, 512
        ADDI32 r18, r0, 0xFF
        CALL32 sd_cmd
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
.ok:    STORE32_32 r24, r0, SD_TYPE
        ADDI32 r16, r0, SD_FAST
        STORE32_32 r16, r0, SD_CTRLV
        ADDR32 r26, r24, r0
        JMP32 .end
.fail:  ADDI32 r26, r0, 0
.end:   ADDI32 r16, r0, 0
        CALL32 sd_cs
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDR32 r16, r26, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; sd_read(r16 = セクタ番号, r17 = 置き場所) → r16 = 0 なら成功、1 なら失敗
bios_sd_read:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDR32 r24, r16, r0
        ADDR32 r25, r17, r0
        ADDI32 r26, r0, 1
        LOAD32_32 r16, r0, SD_TYPE
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret                   ; 初期化できていない
        CMPEQI32 p1, r16, 3
        SHLI32 r17, r24, 9              ; SDSC はバイト単位の番地で指定する
        SEL32 r24, r24, r17, p1
        ADDI32 r16, r0, 1
        CALL32 sd_cs
        ADDI32 r16, r0, 17              ; CMD17（1 セクタ読む）
        ADDR32 r17, r24, r0
        ADDI32 r18, r0, 0xFF
        CALL32 sd_cmd
        CMPNEI32 p1, r16, 0
        BR32 p1, .err
        ADDI32 r24, r0, 0               ; データの始まり（0xFE）を待つ
.tok:   ADDI32 r16, r0, 0xFF
        CALL32 spi
        CMPEQI32 p1, r16, 0xFE
        BR32 p1, .data
        CMPNEI32 p1, r16, 0xFF          ; それ以外はエラーの印
        BR32 p1, .err
        ADDI32 r24, r24, 1
        CMPLTUI32 p1, r24, 65536
        BR32 p1, .tok
        JMP32 .err
.data:  ADDI32 r24, r25, 512
.d:     ADDI32 r16, r0, 0xFF
        CALL32 spi
        STORE8_32 r16, r25, 0
        ADDI32 r25, r25, 1
        CMPLTUR32 p1, r25, r24
        BR32 p1, .d
        ADDI32 r16, r0, 0xFF            ; CRC（2 バイト。確かめない）
        CALL32 spi
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r26, r0, 0
        JMP32 .end
.err:   ADDI32 r26, r0, 1
.end:   ADDI32 r16, r0, 0
        CALL32 sd_cs
        ADDI32 r16, r0, 0xFF
        CALL32 spi
.ret:   ADDR32 r16, r26, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; sd_write(r16 = セクタ番号, r17 = 512 バイト) → r16 = 0 なら成功、1 なら失敗
bios_sd_write:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDR32 r24, r16, r0
        ADDR32 r25, r17, r0
        ADDI32 r26, r0, 1
        LOAD32_32 r16, r0, SD_TYPE
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        CMPEQI32 p1, r16, 3
        SHLI32 r17, r24, 9              ; SDSC はバイト単位の番地
        SEL32 r24, r24, r17, p1
        ADDI32 r16, r0, 1
        CALL32 sd_cs
        ADDI32 r16, r0, 24              ; CMD24（1 セクタ書く）
        ADDR32 r17, r24, r0
        ADDI32 r18, r0, 0xFF
        CALL32 sd_cmd
        CMPNEI32 p1, r16, 0
        BR32 p1, .err
        ADDI32 r16, r0, 0xFF            ; 1 バイトあけて
        CALL32 spi
        ADDI32 r16, r0, 0xFE            ; データの始まり
        CALL32 spi
        ADDI32 r24, r25, 512
.d:     LOAD8U_32 r16, r25, 0
        CALL32 spi
        ADDI32 r25, r25, 1
        CMPLTUR32 p1, r25, r24
        BR32 p1, .d
        ADDI32 r16, r0, 0xFF            ; CRC（使わない）
        CALL32 spi
        ADDI32 r16, r0, 0xFF
        CALL32 spi
        ADDI32 r16, r0, 0xFF            ; 受け取ったかどうか（下位 5bit が 00101 なら受け取った）
        CALL32 spi
        ANDI32 r16, r16, 0x1F
        CMPNEI32 p1, r16, 0x05
        BR32 p1, .err
        LOAD32_32 r24, r0, TIMER_COUNT  ; 書き終わるまで 0 が返る。最大 0.5 秒待つ
.busy:  ADDI32 r16, r0, 0xFF
        CALL32 spi
        CMPNEI32 p1, r16, 0
        BR32 p1, .ok
        LOAD32_32 r16, r0, TIMER_COUNT
        SUBR32 r16, r16, r24
        CMPLTUI32 p1, r16, 500000
        BR32 p1, .busy
        JMP32 .err
.ok:    ADDI32 r26, r0, 0
        JMP32 .end
.err:   ADDI32 r26, r0, 1
.end:   ADDI32 r16, r0, 0
        CALL32 sd_cs
        ADDI32 r16, r0, 0xFF
        CALL32 spi
.ret:   ADDR32 r16, r26, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; kbhit() → r16 = キーが来ていれば 1
bios_kbhit:
        LOAD32_32 r16, r0, UART_STATUS
        SHRI32 r16, r16, 1
        ANDI32 r16, r16, 1
        RET32

; setattr(r16 = 色) → r16 = 前の色
bios_setattr:
        LOAD32_32 r17, r0, ATTR
        STORE32_32 r16, r0, ATTR
        ADDR32 r16, r17, r0
        RET32

; ==================================================================
; ブートローダー：FAT のルートディレクトリから MYDOS.SYS を探して読む（読み出しだけの小さな FAT）
; ==================================================================

; rd16(r16 = 番地) → r16。整列していない番地からも読める（BPB 用）。r17 を壊す
rd16:
        LOAD8U_32 r17, r16, 1
        LOAD8U_32 r16, r16, 0
        SHLI32 r17, r17, 8
        ORR32 r16, r16, r17
        RET32

; rd32(r16 = 番地) → r16。r17, r18 を壊す
rd32:
        LOAD8U_32 r17, r16, 3
        LOAD8U_32 r18, r16, 2
        SHLI32 r17, r17, 8
        ORR32 r17, r17, r18
        LOAD8U_32 r18, r16, 1
        SHLI32 r17, r17, 8
        ORR32 r17, r17, r18
        LOAD8U_32 r18, r16, 0
        SHLI32 r17, r17, 8
        ORR32 r16, r17, r18
        RET32

; b_lba(r16 = クラスタ) → r16 = 最初のセクタ。r17 を壊す
b_lba:
        ADDI32 r16, r16, -2
        LOAD32_32 r17, r0, B_SPC
        MULR32 r16, r16, r17
        LOAD32_32 r17, r0, B_DATA
        ADDR32 r16, r16, r17
        RET32

; b_next(r16 = クラスタ) → r16 = 次のクラスタ。終わり・読めないなら 0
b_next:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r17, r0, B_TYPE
        CMPEQI32 p2, r17, 32
        SHLI32 r18, r16, 1
        SHLI32 r19, r16, 2
        SEL32 r24, r19, r18, p2         ; FAT の中のバイト位置
        SHRI32 r16, r24, 9
        LOAD32_32 r17, r0, B_FAT
        ADDR32 r16, r16, r17
        ADDI32 r17, r0, FATBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .end
        ANDI32 r24, r24, 511
        LOAD32_32 r17, r0, B_TYPE
        CMPEQI32 p2, r17, 32
        BR32 p2, .f32
        LOAD16U_32 r16, r24, FATBUF
        ADDI32 r18, r0, 0xFFF8
        JMP32 .chk
.f32:   LOAD32_32 r16, r24, FATBUF
        ANDI32 r16, r16, 0x0FFFFFFF
        ADDI32 r18, r0, 0x0FFFFFF8
.chk:   CMPGEUR32 p1, r16, r18
        BR32 p1, .end
        CMPLTUI32 p1, r16, 2
        BR32 p1, .end
        JMP32 .ret
.end:   ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; load_sys() → r16 = 1 なら MYDOS.SYS を 0x20000 に読み込んだ
load_sys:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        STORE32_32 r28, sp, 20
        LOAD32_32 r16, r0, SD_TYPE
        CMPNEI32 p1, r16, 0
        BR32 p1, .card
        CALL32 bios_sd_init
        CMPEQI32 p1, r16, 0
        BR32 p1, .fail
.card:  ADDI32 r16, r0, 0               ; セクタ 0：MBR か、パーティションなしならブートセクタ
        ADDI32 r17, r0, SECBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
        LOAD16U_32 r16, r0, SECBUF + 510
        CMPNEI32 p1, r16, 0xAA55
        BR32 p1, .fail
        ADDI32 r24, r0, 0               ; r24 = パーティションの始まり
        LOAD8U_32 r16, r0, SECBUF
        CMPEQI32 p1, r16, 0xEB
        BR32 p1, .maybe
        CMPEQI32 p1, r16, 0xE9
        BR32 p1, .maybe
        JMP32 .mbr
.maybe: ADDI32 r16, r0, SECBUF + 11
        CALL32 rd16
        CMPEQI32 p1, r16, 512
        BR32 p1, .bpb
.mbr:   ADDI32 r16, r0, SECBUF + 0x1C6
        CALL32 rd32
        ADDR32 r24, r16, r0
        CMPEQI32 p1, r24, 0
        BR32 p1, .fail
        ADDR32 r16, r24, r0
        ADDI32 r17, r0, SECBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
        LOAD16U_32 r16, r0, SECBUF + 510
        CMPNEI32 p1, r16, 0xAA55
        BR32 p1, .fail
        ADDI32 r16, r0, SECBUF + 11
        CALL32 rd16
        CMPNEI32 p1, r16, 512
        BR32 p1, .fail
.bpb:   LOAD8U_32 r25, r0, SECBUF + 13  ; 1 クラスタのセクタ数
        CMPEQI32 p1, r25, 0
        BR32 p1, .fail
        STORE32_32 r25, r0, B_SPC
        ADDI32 r16, r0, SECBUF + 14     ; FAT の場所 = 始まり + 予約セクタ数
        CALL32 rd16
        ADDR32 r16, r16, r24
        STORE32_32 r16, r0, B_FAT
        ADDI32 r16, r0, SECBUF + 22     ; FAT の大きさ
        CALL32 rd16
        ADDR32 r26, r16, r0
        CMPNEI32 p1, r26, 0
        BR32 p1, .fsz
        ADDI32 r16, r0, SECBUF + 36
        CALL32 rd32
        ADDR32 r26, r16, r0
.fsz:   LOAD8U_32 r16, r0, SECBUF + 16
        MULR32 r26, r26, r16
        LOAD32_32 r16, r0, B_FAT
        ADDR32 r26, r26, r16
        STORE32_32 r26, r0, B_ROOT
        ADDI32 r16, r0, SECBUF + 17     ; ルートディレクトリのセクタ数（FAT32 は 0）
        CALL32 rd16
        SHLI32 r16, r16, 5
        ADDI32 r16, r16, 511
        SHRI32 r16, r16, 9
        STORE32_32 r16, r0, B_RSECS
        ADDR32 r26, r26, r16
        STORE32_32 r26, r0, B_DATA
        ADDI32 r16, r0, SECBUF + 19     ; 全セクタ数 → クラスタ数 → FAT16 か FAT32 か
        CALL32 rd16
        CMPNEI32 p1, r16, 0
        BR32 p1, .tot
        ADDI32 r16, r0, SECBUF + 32
        CALL32 rd32
.tot:   SUBR32 r17, r26, r24
        SUBR32 r16, r16, r17
        DIVUR32 r16, r16, r25
        CMPLTUI32 p1, r16, 4085
        BR32 p1, .fail
        ADDI32 r17, r0, 16
        STORE32_32 r17, r0, B_TYPE
        STORE32_32 r0, r0, B_RCLUS
        CMPLTUI32 p1, r16, 65525
        BR32 p1, .root
        ADDI32 r17, r0, 32
        STORE32_32 r17, r0, B_TYPE
        ADDI32 r16, r0, SECBUF + 44
        CALL32 rd32
        STORE32_32 r16, r0, B_RCLUS
.root:  LOAD32_32 r26, r0, B_RCLUS      ; r27 = 読むセクタ、r28 = このまとまりの残り、r26 = クラスタ（FAT16 は 0）
        LOAD32_32 r27, r0, B_ROOT
        LOAD32_32 r28, r0, B_RSECS
        CMPEQI32 p1, r26, 0
        BR32 p1, .dsec
        ADDR32 r16, r26, r0
        CALL32 b_lba
        ADDR32 r27, r16, r0
        LOAD32_32 r28, r0, B_SPC
.dsec:  CMPNEI32 p1, r28, 0
        BR32 p1, .rd
        CMPEQI32 p1, r26, 0             ; FAT16 のルートの終わり
        BR32 p1, .fail
        ADDR32 r16, r26, r0
        CALL32 b_next
        ADDR32 r26, r16, r0
        CMPEQI32 p1, r26, 0
        BR32 p1, .fail
        CALL32 b_lba
        ADDR32 r27, r16, r0
        LOAD32_32 r28, r0, B_SPC
.rd:    ADDR32 r16, r27, r0
        ADDI32 r17, r0, SECBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
        ADDI32 r27, r27, 1
        ADDI32 r28, r28, -1
        ADDI32 r24, r0, SECBUF          ; この中の 16 項目を見る
.ent:   LOAD8U_32 r16, r24, 0
        CMPEQI32 p1, r16, 0             ; ここで終わり
        BR32 p1, .fail
        LOAD8U_32 r16, r24, 11          ; ディレクトリ・ボリュームラベル・長い名前は違う
        ANDI32 r16, r16, 0x18
        CMPNEI32 p1, r16, 0
        BR32 p1, .next
        ADDI32 r16, r0, 0
.cmp:   ADDR32 r17, r24, r16
        LOAD8U_32 r17, r17, 0
        LOAD8U_32 r18, r16, s_sysname
        CMPNER32 p1, r17, r18
        BR32 p1, .next
        ADDI32 r16, r16, 1
        CMPLTI32 p1, r16, 11
        BR32 p1, .cmp
        JMP32 .found
.next:  ADDI32 r24, r24, 32
        CMPLTUI32 p1, r24, SECBUF + 512
        BR32 p1, .ent
        JMP32 .dsec
.found: LOAD16U_32 r26, r24, 26         ; 最初のクラスタ
        LOAD16U_32 r16, r24, 20
        LOAD32_32 r17, r0, B_TYPE
        CMPEQI32 p1, r17, 32
        SHLI32 r16, r16, 16
        SEL32 r16, r16, r0, p1
        ORR32 r26, r26, r16
        LOAD32_32 r25, r24, 28          ; 大きさ
        CMPEQI32 p1, r25, 0
        BR32 p1, .fail
        ADDI32 r16, r0, SYS_MAX
        CMPLTUR32 p1, r16, r25
        BR32 p1, .fail
        ADDI32 r24, r0, OS_BASE         ; r24 = 書く先、r25 = 終わり
        ADDI32 r25, r25, OS_BASE
.clus:  CMPLTUI32 p1, r26, 2
        BR32 p1, .fail
        ADDR32 r16, r26, r0
        CALL32 b_lba
        ADDR32 r27, r16, r0
        LOAD32_32 r28, r0, B_SPC
.sec:   ADDR32 r16, r27, r0             ; 512 バイトずつ、そのまま置き場所へ読む
        ADDR32 r17, r24, r0
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
        ADDI32 r24, r24, 512
        CMPGEUR32 p1, r24, r25
        BR32 p1, .done
        ADDI32 r27, r27, 1
        ADDI32 r28, r28, -1
        CMPNEI32 p1, r28, 0
        BR32 p1, .sec
        ADDR32 r16, r26, r0
        CALL32 b_next
        ADDR32 r26, r16, r0
        JMP32 .clus
.done:  ADDI32 r16, r0, 1
        JMP32 .ret
.fail:  ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        LOAD32_32 r28, sp, 20
        ADDI32 sp, sp, 24
        RET32

s_bios:     .asciz "MyCPU BIOS Version 1.00   (C) 2026 MyCPU Project\n\n"
s_cpu:      .asciz "CPU         : MyCPU-32 @ 27MHz\n"
s_memtest:  .asciz "Memory Test : "
s_kbok:     .asciz " KB OK\n"
s_memfail:  .asciz " FAILED at 0x"
s_sd:       .asciz "SD card     : "
s_sd0:      .asciz "not found\n\n"
s_sd1:      .asciz "SDSC (v1)\n\n"
s_sd2:      .asciz "SDSC\n\n"
s_sd3:      .asciz "SDHC/SDXC\n\n"
        .align 4
sd_names:   .word s_sd0, s_sd1, s_sd2, s_sd3
s_press:    .asciz "Press U for UART boot...\n"
s_starting: .asciz "Starting MyDOS...\n\n"
s_nonsys:   .asciz "\nNon-System disk or disk error\nReplace and press any key when ready (U = UART boot)\n"
s_sysname:  .ascii "MYDOS   SYS"
s_uartboot: .asciz "UART boot: send 'MC' + length (4 bytes, little endian) + image\n"
s_loaded:   .asciz "Loaded "
s_bytes:    .asciz " bytes. Jumping to 0x00020000\n\n"
s_toobig:   .asciz "Image too large (max 45056 bytes). System halted.\n"
s_trap1:    .asciz "\n *** EXCEPTION  CAUSE="
s_trap2:    .asciz "  EPC="
s_trap3:    .asciz "  System halted. *** \n"


