; mydos.asm — BIOS（ROM）＋ブートローダー＋MyDOS（SD カードの FAT を読む）
;
; 起動の流れ
;   1. BIOS：画面を消して見出し、メモリテスト
;   2. 1 秒待つ。U キーなら UART から起動（tools/mkboot.js で作ったものを送る）、ほかのキーか時間切れなら次へ
;   3. ブートローダー：ROM の中の MyDOS を RAM の 0x20000 に写して、そこへ飛ぶ
;   4. MyDOS：SD カードの FAT（FAT16 / FAT32）を読み、AUTOEXEC.BAT があれば実行してから C:\> を出す
;
; ドライブ C: は SD カード（SPI でつなぐ。読み出しだけ）。ルートディレクトリのファイルを DIR・TYPE で見られ、
; .EXE・.COM は RAM の 0x23000 に読み込んで実行、.BAT は 1 行ずつコマンドとして実行する。
;   .EXE：先頭 16 バイトがヘッダ。'MZ'、ヘッダの大きさ（2 バイト）、読み込む番地、開始番地、本体の大きさ（各 4 バイト）
;         読み込む番地は 0x23000 だけ対応
;   .COM：ヘッダなし。そのまま 0x23000 に置いて 0x23000 から実行
; プログラムは r16 に引数の文字列を受け取り、RET32 で戻ると C:\> に戻る（tools/mkdisk.js で作る）。
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
OS_MAX      = 0x7000                    ; UART 起動で読み込めるのは 0x20000〜0x26FFF（28KB）まで
TPA         = 0x00023000                ; .EXE・.COM を読み込む場所（MyDOS は 0x20000〜0x22FFF）
TPA_END     = 0x00027000
SD_DATA     = 0x00010030                ; SPI：書くと 1 バイト送り、読むと受け取った 1 バイト
SD_CTRL     = 0x00010034                ; bit0 = CS（1 で選ぶ）、bit15〜8 = SCK の分周
SD_STATUS   = 0x00010038                ; bit0 = 送受信中
SD_SLOW     = 33 << 8                   ; SCK = 27MHz ÷ (2 × 34) ≒ 400kHz（初期化はこれ以下で）
SD_FAST     = 0 << 8                    ; SCK = 27MHz ÷ 2 = 13.5MHz
SECBUF      = 0x00027100                ; セクタ 1 つ分の置き場（512 バイト）
FATBUF      = 0x00027300                ; FAT を読む置き場（512 バイト）
BATBUF      = 0x00027500                ; .BAT を読み込む置き場
BATMAX      = 0x400
BDA         = 0x00027000                ; BIOS の変数（BIOS Data Area）
CUR_X       = BDA + 0                   ; カーソルの桁
CUR_Y       = BDA + 4                   ; カーソルの行
ATTR        = BDA + 8                   ; 文字の色
LAST_CR     = BDA + 12                  ; 直前の入力が \r だった（\r\n を 1 回の Enter にする）
SD_TYPE     = BDA + 16                  ; SD カードの種類（0 = なし、1 = SDSC v1、2 = SDSC v2、3 = SDHC/SDXC）
SD_CTRLV    = BDA + 20                  ; SD_CTRL に書く分周（CS は bit0 で足す）
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
        JMP32 bios_putg                 ; 0x50 putg(r16 = 文字)：制御文字も字の形のまま画面に出す
        JMP32 bios_sd_init              ; 0x58 sd_init() → r16 = SD カードの種類（0 = なし）
        JMP32 bios_sd_read              ; 0x60 sd_read(r16 = セクタ番号, r17 = 置き場所 512 バイト) → r16 = 0 なら成功

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

        ; ---- SD カード ----
        ADDI32 r16, r0, s_sd
        CALL32 bios_puts
        CALL32 bios_sd_init
        SHLI32 r16, r16, 2
        LOAD32_32 r16, r16, sd_names
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
        STORE32_32 r0, r0, fs_ok
        STORE32_32 r0, r0, quiet
        ADDI32 r16, r0, s_banner
        CALL32 bios_puts
        ; SD カードが読めて AUTOEXEC.BAT があれば実行する
        CALL32 fs_mount
        CMPEQI32 p1, r16, 0
        BR32 p1, shell
        ADDI32 r16, r0, s_autoexec
        CALL32 to83
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        BR32 p1, shell
        CALL32 run_batch

shell:
        LOAD32_32 r16, r0, quiet        ; コマンドの後は 1 行あける（CLS の後はあけない）
        STORE32_32 r0, r0, quiet
        CMPNEI32 p1, r16, 0
        BR32 p1, .prompt
        ADDI32 r16, r0, 10
        CALL32 bios_putc
.prompt:
        ADDI32 r16, r0, s_prompt
        CALL32 bios_puts
        ADDI32 r16, r0, linebuf
        ADDI32 r17, r0, 72
        CALL32 bios_getline
        CALL32 exec_line
        JMP32 shell

; exec_line()：linebuf の 1 行を実行する
exec_line:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        CALL32 parse
        LOAD8U_32 r16, r0, cmdbuf
        CMPEQI32 p1, r16, 0             ; 空の行
        BR32 p1, .ret
        ADDI32 r24, r0, commands        ; 組み込みのコマンド
.find:  LOAD32_32 r16, r24, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .file
        ADDI32 r17, r0, cmdbuf
        CALL32 streq
        CMPNEI32 p1, r16, 0
        BR32 p1, .run
        ADDI32 r24, r24, 8
        JMP32 .find
.run:   LOAD32_32 r17, r24, 4
        LOAD32_32 r16, r0, args
        CALLR32 r17
        JMP32 .ret
.file:  CALL32 run_file                 ; .EXE・.COM・.BAT
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r16, r0, s_bad
        CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

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

; to83(r16 = "README.TXT") → name83 に 11 文字の形（"README  TXT"）。r16 = 1 なら成功。r17〜r20 を壊す
to83:
        ADDI32 r17, r0, 0x20202020      ; まず空白で埋める
        STORE32_32 r17, r0, name83
        STORE32_32 r17, r0, name83 + 4
        STORE32_32 r17, r0, name83 + 8
        ADDI32 r18, r0, 0               ; 書く位置
        ADDI32 r19, r0, 8               ; この部分の終わり（名前 8、拡張子 11）
.c:     LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
        CMPEQI32 p1, r17, ' '
        BR32 p1, .end
        CMPNEI32 p1, r17, '.'
        BR32 p1, .ch
        CMPEQI32 p1, r19, 11            ; 2 つ目の '.'
        BR32 p1, .bad
        CMPEQI32 p1, r18, 0             ; 名前が空
        BR32 p1, .bad
        ADDI32 r18, r0, 8
        ADDI32 r19, r0, 11
        ADDI32 r16, r16, 1
        JMP32 .c
.ch:    CMPGEUR32 p1, r18, r19          ; 長すぎる
        BR32 p1, .bad
        ADDI32 r20, r17, -'a'
        CMPLTUI32 p1, r20, 26
        ADDI32 r20, r17, -32
        SEL32 r17, r20, r17, p1
        STORE8_32 r17, r18, name83
        ADDI32 r18, r18, 1
        ADDI32 r16, r16, 1
        JMP32 .c
.end:   CMPEQI32 p1, r18, 0
        BR32 p1, .bad
        ADDI32 r16, r0, 1
        RET32
.bad:   ADDI32 r16, r0, 0
        RET32

; ---- ファイルの実行 ----

; run_file() → r16 = 1 なら実行した（エラーを出した場合も含む）、0 ならそういうファイルはない
; cmdbuf に '.' があればその名前、なければ .EXE → .COM → .BAT の順に探す
run_file:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDI32 r16, r0, cmdbuf          ; '.' があるか
.dot:   LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .noext
        CMPEQI32 p1, r17, '.'
        BR32 p1, .named
        ADDI32 r16, r16, 1
        JMP32 .dot
.named: ADDI32 r16, r0, cmdbuf
        CALL32 to83
        CMPEQI32 p1, r16, 0
        BR32 p1, .no
        CALL32 need_fs
        CMPEQI32 p1, r16, 0
        BR32 p1, .yes                   ; カードがない（メッセージは出した）
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        BR32 p1, .no
        JMP32 .kind
.noext: ADDI32 r16, r0, cmdbuf          ; 8 文字までの名前
        CALL32 to83
        CMPEQI32 p1, r16, 0
        BR32 p1, .no
        CALL32 need_fs
        CMPEQI32 p1, r16, 0
        BR32 p1, .yes
        ADDI32 r24, r0, exts
.try:   LOAD8U_32 r16, r24, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .no
        STORE8_32 r16, r0, name83 + 8
        LOAD8U_32 r16, r24, 1
        STORE8_32 r16, r0, name83 + 9
        LOAD8U_32 r16, r24, 2
        STORE8_32 r16, r0, name83 + 10
        CALL32 fs_find
        CMPNEI32 p1, r16, 0
        BR32 p1, .kind
        ADDI32 r24, r24, 4
        JMP32 .try
.kind:  ADDI32 r16, r0, ent + 8         ; 拡張子で分ける
        ADDI32 r17, r0, x_bat
        CALL32 ext_is
        CMPNEI32 p1, r16, 0
        BR32 p1, .bat
        ADDI32 r16, r0, ent + 8
        ADDI32 r17, r0, x_exe
        CALL32 ext_is
        CMPNEI32 p1, r16, 0
        BR32 p1, .prog
        ADDI32 r16, r0, ent + 8
        ADDI32 r17, r0, x_com
        CALL32 ext_is
        CMPNEI32 p1, r16, 0
        BR32 p1, .prog
.no:    ADDI32 r16, r0, 0
        JMP32 .ret
.bat:   CALL32 run_batch
        JMP32 .yes
.prog:  CALL32 run_prog
.yes:   ADDI32 r16, r0, 1
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; ext_is(r16, r17) → 3 文字が同じなら 1。r18, r19 を壊す
ext_is:
        ADDI32 r19, r16, 3
.l:     LOAD8U_32 r18, r16, 0
        LOAD8U_32 r20, r17, 0
        CMPNER32 p1, r18, r20
        BR32 p1, .ne
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 1
        CMPLTUR32 p1, r16, r19
        BR32 p1, .l
        ADDI32 r16, r0, 1
        RET32
.ne:    ADDI32 r16, r0, 0
        RET32

; run_prog()：ent の .EXE・.COM を TPA に読み込んで実行する
run_prog:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        LOAD32_32 r16, r0, ent + 28     ; 大きさ
        ADDI32 r17, r0, TPA_END - TPA - 4
        CMPLTUR32 p1, r17, r16
        BR32 p1, .big
        CALL32 f_open
        ADDI32 r24, r0, TPA             ; 写す先
.rd:    CALL32 f_read
        CMPEQI32 p1, r16, 0
        BR32 p1, .loaded
        ADDI32 r17, r0, SECBUF
        ADDR32 r18, r17, r16
.cp:    LOAD32_32 r19, r17, 0
        STORE32_32 r19, r24, 0
        ADDI32 r17, r17, 4
        ADDI32 r24, r24, 4
        CMPLTUR32 p1, r17, r18
        BR32 p1, .cp
        JMP32 .rd
.loaded:
        LOAD32_32 r16, r0, f_err
        CMPNEI32 p1, r16, 0
        BR32 p1, .ioerr
        ADDI32 r25, r0, TPA             ; r25 = 開始番地
        ADDI32 r16, r0, ent + 8
        ADDI32 r17, r0, x_com
        CALL32 ext_is
        CMPNEI32 p1, r16, 0
        BR32 p1, .go
        ; .EXE：ヘッダを確かめて、本体を TPA の先頭へずらす
        LOAD16U_32 r16, r0, TPA
        CMPNEI32 p1, r16, 0x5A4D        ; 'M' 'Z'
        BR32 p1, .badexe
        LOAD16U_32 r17, r0, TPA + 2     ; ヘッダの大きさ
        LOAD32_32 r18, r0, TPA + 4      ; 読み込む番地
        LOAD32_32 r25, r0, TPA + 8      ; 開始番地
        LOAD32_32 r26, r0, TPA + 12     ; 本体の大きさ
        CMPNEI32 p1, r18, TPA
        BR32 p1, .badexe
        ANDI32 r19, r17, 3
        CMPNEI32 p1, r19, 0
        BR32 p1, .badexe
        ADDR32 r19, r17, r26            ; ヘッダ + 本体 ≦ ファイルの大きさ
        LOAD32_32 r20, r0, ent + 28
        CMPLTUR32 p1, r20, r19
        BR32 p1, .badexe
        ADDI32 r19, r25, -TPA           ; 開始番地が本体の中
        CMPGEUR32 p1, r19, r26
        BR32 p1, .badexe
        ADDI32 r17, r17, TPA            ; 写す元
        ADDI32 r18, r0, TPA             ; 写す先（前へずらすので先頭から写してよい）
        ADDR32 r19, r18, r26
.mv:    CMPGEUR32 p1, r18, r19
        BR32 p1, .go
        LOAD32_32 r20, r17, 0
        STORE32_32 r20, r18, 0
        ADDI32 r17, r17, 4
        ADDI32 r18, r18, 4
        JMP32 .mv
.go:    STORE32_32 sp, r0, saved_sp     ; プログラムが SP を戻し忘れても大丈夫なように
        LOAD32_32 r16, r0, args
        CALLR32 r25
        LOAD32_32 sp, r0, saved_sp
        ADDI32 r16, r0, 0x07            ; 色も元に戻す
        STORE32_32 r16, r0, ATTR
        JMP32 .ret
.big:   ADDI32 r16, r0, s_toobig2
        JMP32 .say
.badexe:
        ADDI32 r16, r0, s_badexe
        JMP32 .say
.ioerr: ADDI32 r16, r0, s_readerr
.say:   CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; run_batch()：ent の .BAT を 1 行ずつ実行する。
; 途中で別の .BAT を実行すると、そちらへ移って元には戻らない（MS-DOS と同じ）
run_batch:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r16, r0, ent + 28
        ADDI32 r17, r0, BATMAX
        CMPLTUR32 p1, r17, r16
        BR32 p1, .big
        CALL32 f_open
        ADDI32 r24, r0, BATBUF
.rd:    CALL32 f_read
        CMPEQI32 p1, r16, 0
        BR32 p1, .loaded
        ADDI32 r17, r0, SECBUF
        ADDR32 r18, r17, r16
.cp:    LOAD8U_32 r19, r17, 0
        STORE8_32 r19, r24, 0
        ADDI32 r17, r17, 1
        ADDI32 r24, r24, 1
        CMPLTUR32 p1, r17, r18
        BR32 p1, .cp
        JMP32 .rd
.loaded:
        STORE32_32 r24, r0, bat_end
        ADDI32 r16, r0, BATBUF
        STORE32_32 r16, r0, bat_ptr
.line:  LOAD32_32 r16, r0, bat_ptr      ; 1 行を linebuf へ（\r は捨てる）
        LOAD32_32 r17, r0, bat_end
        CMPGEUR32 p1, r16, r17
        BR32 p1, .ret
        ADDI32 r18, r0, linebuf
        ADDI32 r20, r0, linebuf + 127
.c:     CMPGEUR32 p1, r16, r17
        BR32 p1, .eol
        LOAD8U_32 r19, r16, 0
        ADDI32 r16, r16, 1
        CMPEQI32 p1, r19, 10
        BR32 p1, .eol
        CMPEQI32 p1, r19, 13
        BR32 p1, .c
        CMPGEUR32 p1, r18, r20
        BR32 p1, .c
        STORE8_32 r19, r18, 0
        ADDI32 r18, r18, 1
        JMP32 .c
.eol:   STORE8_32 r0, r18, 0
        STORE32_32 r16, r0, bat_ptr
        LOAD8U_32 r16, r0, linebuf
        CMPEQI32 p1, r16, 0
        BR32 p1, .line
        CMPNEI32 p1, r16, '@'           ; '@' で始まる行は表示しない
        BR32 p1, .echo
        ADDI32 r16, r0, ' '
        STORE8_32 r16, r0, linebuf
        JMP32 .exec
.echo:  ADDI32 r16, r0, 10
        CALL32 bios_putc
        ADDI32 r16, r0, s_prompt
        CALL32 bios_puts
        ADDI32 r16, r0, linebuf
        CALL32 bios_puts
        ADDI32 r16, r0, 10
        CALL32 bios_putc
.exec:  CALL32 exec_line
        JMP32 .line
.big:   ADDI32 r16, r0, s_batbig
        CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; ==================================================================
; FAT（読み出しだけ。FAT16 と FAT32、ルートディレクトリ）
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

; need_fs() → r16 = 1 なら読める。読めなければ "Not ready" を出して 0
need_fs:
        LOAD32_32 r16, r0, fs_ok
        CMPNEI32 p1, r16, 0
        BR32 p1, .ok
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 fs_mount
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        CMPNEI32 p1, r16, 0
        BR32 p1, .ok
        ADDR32 r20, lr, r0
        ADDI32 r16, r0, s_notready
        CALL32 bios_puts
        ADDR32 lr, r20, r0
        ADDI32 r16, r0, 0
        RET32
.ok:    ADDI32 r16, r0, 1
        RET32

; fs_mount() → r16 = 1 なら成功。SD カードの MBR と BPB を読んで、FAT の場所を覚える
fs_mount:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r0, r0, fs_ok
        ADDI32 r16, r0, -1
        STORE32_32 r16, r0, fat_cache
        LOAD32_32 r16, r0, SD_TYPE      ; 起動後に挿したカードも読めるように
        CMPNEI32 p1, r16, 0
        BR32 p1, .card
        CALL32 bios_sd_init
        CMPEQI32 p1, r16, 0
        BR32 p1, .fail
.card:  ADDI32 r16, r0, 0               ; セクタ 0（MBR か、パーティションなしならブートセクタ）
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
.mbr:   ADDI32 r16, r0, SECBUF + 0x1C6  ; 1 つ目のパーティションの開始セクタ
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
        ADDI32 r16, r0, SECBUF + 11     ; 1 セクタ 512 バイトだけ対応
        CALL32 rd16
        CMPNEI32 p1, r16, 512
        BR32 p1, .fail
.bpb:   STORE32_32 r24, r0, part_lba
        LOAD8U_32 r25, r0, SECBUF + 13  ; r25 = 1 クラスタのセクタ数
        CMPEQI32 p1, r25, 0
        BR32 p1, .fail
        STORE32_32 r25, r0, spc
        ADDI32 r16, r0, SECBUF + 14     ; 予約セクタ数
        CALL32 rd16
        ADDR32 r16, r16, r24
        STORE32_32 r16, r0, fat_lba
        ADDI32 r16, r0, SECBUF + 22     ; FAT の大きさ（FAT16）
        CALL32 rd16
        ADDR32 r26, r16, r0
        CMPNEI32 p1, r26, 0
        BR32 p1, .fsz
        ADDI32 r16, r0, SECBUF + 36     ; FAT の大きさ（FAT32）
        CALL32 rd32
        ADDR32 r26, r16, r0
.fsz:   LOAD8U_32 r16, r0, SECBUF + 16  ; FAT の数
        MULR32 r26, r26, r16
        LOAD32_32 r16, r0, fat_lba
        ADDR32 r26, r26, r16
        STORE32_32 r26, r0, root_lba    ; FAT16 のルートディレクトリ
        ADDI32 r16, r0, SECBUF + 17     ; ルートディレクトリの項目数（FAT32 は 0）
        CALL32 rd16
        SHLI32 r16, r16, 5
        ADDI32 r16, r16, 511
        SHRI32 r16, r16, 9
        STORE32_32 r16, r0, root_secs
        ADDR32 r26, r26, r16
        STORE32_32 r26, r0, data_lba
        ADDI32 r16, r0, SECBUF + 19     ; 全セクタ数
        CALL32 rd16
        CMPNEI32 p1, r16, 0
        BR32 p1, .tot
        ADDI32 r16, r0, SECBUF + 32
        CALL32 rd32
.tot:   SUBR32 r17, r26, r24            ; データ領域より前のセクタ数を引いて、クラスタ数に
        SUBR32 r16, r16, r17
        DIVUR32 r16, r16, r25
        STORE32_32 r16, r0, nclus
        CMPLTUI32 p1, r16, 4085         ; FAT12 は対応しない
        BR32 p1, .fail
        ADDI32 r17, r0, -1
        STORE32_32 r17, r0, fs_free     ; 空きはまだ数えていない
        CMPLTUI32 p1, r16, 65525
        BR32 p1, .f16
        ; FAT32
        ADDI32 r16, r0, 32
        STORE32_32 r16, r0, fs_type
        ADDI32 r16, r0, SECBUF + 44     ; ルートディレクトリのクラスタ
        CALL32 rd32
        STORE32_32 r16, r0, root_clus
        ADDI32 r16, r0, SECBUF + 67
        CALL32 rd32
        STORE32_32 r16, r0, fs_serial
        ADDI32 r25, r0, SECBUF + 71     ; ボリュームラベル
        CALL32 copy_label
        ADDI32 r16, r0, SECBUF + 48     ; FSInfo（空きクラスタ数が書いてある）
        CALL32 rd16
        ADDR32 r16, r16, r24
        ADDI32 r17, r0, SECBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .ok
        LOAD32_32 r16, r0, SECBUF + 484
        CMPNEI32 p1, r16, 0x61417272
        BR32 p1, .ok
        LOAD32_32 r16, r0, SECBUF + 488
        STORE32_32 r16, r0, fs_free
        JMP32 .ok
.f16:   ADDI32 r16, r0, 16
        STORE32_32 r16, r0, fs_type
        STORE32_32 r0, r0, root_clus
        ADDI32 r16, r0, SECBUF + 39
        CALL32 rd32
        STORE32_32 r16, r0, fs_serial
        ADDI32 r25, r0, SECBUF + 43
        CALL32 copy_label
.ok:    ADDI32 r16, r0, 1
        STORE32_32 r16, r0, fs_ok
        JMP32 .ret
.fail:  ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; copy_label(r25 = BPB のラベル 11 文字) → vol_label。r16, r17 を壊す
copy_label:
        ADDI32 r16, r0, 0
.l:     ADDR32 r17, r25, r16
        LOAD8U_32 r17, r17, 0
        STORE8_32 r17, r16, vol_label
        ADDI32 r16, r16, 1
        CMPLTI32 p1, r16, 11
        BR32 p1, .l
        STORE8_32 r0, r0, vol_label + 11
        RET32

; clus_lba(r16 = クラスタ番号) → r16 = 最初のセクタ。r17 を壊す
clus_lba:
        ADDI32 r16, r16, -2
        LOAD32_32 r17, r0, spc
        MULR32 r16, r16, r17
        LOAD32_32 r17, r0, data_lba
        ADDR32 r16, r16, r17
        RET32

; fat_get(r16 = クラスタ番号) → r16 = FAT の値（FAT32 は下位 28bit）。FAT のセクタは 1 つ覚えておく。r17〜r19 を壊す
fat_get:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p2, r17, 32
        SHLI32 r18, r16, 1
        SHLI32 r19, r16, 2
        SEL32 r24, r19, r18, p2         ; r24 = FAT の中のバイト位置
        SHRI32 r16, r24, 9
        LOAD32_32 r17, r0, fat_lba
        ADDR32 r16, r16, r17
        LOAD32_32 r17, r0, fat_cache
        CMPEQR32 p1, r16, r17
        BR32 p1, .hit
        STORE32_32 r16, r0, fat_cache
        ADDI32 r17, r0, FATBUF
        CALL32 bios_sd_read
        CMPEQI32 p1, r16, 0
        BR32 p1, .hit
        ADDI32 r16, r0, -1              ; 読めなかった（終わりの印として扱われる）
        STORE32_32 r16, r0, fat_cache
        STORE32_32 r16, r0, f_err
        JMP32 .ret
.hit:   ANDI32 r24, r24, 511
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p2, r17, 32
        BR32 p2, .f32
        LOAD16U_32 r16, r24, FATBUF
        JMP32 .ret
.f32:   LOAD32_32 r16, r24, FATBUF
        ANDI32 r16, r16, 0x0FFFFFFF
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; next_clus(r16) → r16 = 次のクラスタ。終わりなら 0。r17〜r19 を壊す
next_clus:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 fat_get
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p1, r17, 32
        ADDI32 r18, r0, 0xFFF8          ; これ以上は「終わり」
        ADDI32 r19, r0, 0x0FFFFFF8
        SEL32 r18, r19, r18, p1
        CMPGEUR32 p1, r16, r18
        BR32 p1, .end
        CMPLTUI32 p1, r16, 2
        BR32 p1, .end
        RET32
.end:   ADDI32 r16, r0, 0
        RET32

; dir_open()：ルートディレクトリを最初から読む準備
dir_open:
        STORE32_32 r0, r0, d_end
        ADDI32 r16, r0, 16
        STORE32_32 r16, r0, d_idx       ; 次は新しいセクタを読む
        LOAD32_32 r16, r0, fs_type
        CMPEQI32 p1, r16, 32
        BR32 p1, .f32
        LOAD32_32 r16, r0, root_lba     ; FAT16：決まった場所の決まった数のセクタ
        STORE32_32 r16, r0, d_lba
        LOAD32_32 r16, r0, root_secs
        STORE32_32 r16, r0, d_left
        STORE32_32 r0, r0, d_clus
        RET32
.f32:   ADDR32 r20, lr, r0              ; FAT32：クラスタのつながり
        LOAD32_32 r16, r0, root_clus
        STORE32_32 r16, r0, d_clus
        CALL32 clus_lba
        STORE32_32 r16, r0, d_lba
        LOAD32_32 r16, r0, spc
        STORE32_32 r16, r0, d_left
        JMPR32 r20

; dir_next() → r16 = 次の項目（SECBUF の中の 32 バイト）。終わりなら 0。消した項目と長い名前の項目は飛ばす
dir_next:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
.again: LOAD32_32 r16, r0, d_end
        CMPNEI32 p1, r16, 0
        BR32 p1, .end
        LOAD32_32 r16, r0, d_idx
        CMPLTI32 p1, r16, 16
        BR32 p1, .have
        LOAD32_32 r16, r0, d_left       ; 次のセクタ
        CMPNEI32 p1, r16, 0
        BR32 p1, .read
        LOAD32_32 r16, r0, d_clus       ; 次のクラスタ（FAT16 のルートなら終わり）
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        CALL32 next_clus
        STORE32_32 r16, r0, d_clus
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        CALL32 clus_lba
        STORE32_32 r16, r0, d_lba
        LOAD32_32 r16, r0, spc
        STORE32_32 r16, r0, d_left
.read:  LOAD32_32 r16, r0, d_lba
        ADDI32 r17, r16, 1
        STORE32_32 r17, r0, d_lba
        LOAD32_32 r17, r0, d_left
        ADDI32 r17, r17, -1
        STORE32_32 r17, r0, d_left
        ADDI32 r17, r0, SECBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .end
        STORE32_32 r0, r0, d_idx
.have:  LOAD32_32 r16, r0, d_idx
        ADDI32 r17, r16, 1
        STORE32_32 r17, r0, d_idx
        SHLI32 r16, r16, 5
        ADDI32 r16, r16, SECBUF
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0             ; ここで終わり
        BR32 p1, .end
        CMPEQI32 p1, r17, 0xE5          ; 消したファイル
        BR32 p1, .again
        LOAD8U_32 r17, r16, 11
        CMPEQI32 p1, r17, 0x0F          ; 長いファイル名の項目
        BR32 p1, .again
        JMP32 .ret
.end:   ADDI32 r16, r0, 1
        STORE32_32 r16, r0, d_end
        ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; fs_find() → r16 = 1 なら見つけて ent に写した。name83 の名前を探す（ボリュームラベルは除く）
fs_find:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        CALL32 dir_open
.l:     CALL32 dir_next
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        ADDR32 r24, r16, r0
        LOAD8U_32 r17, r24, 11
        ANDI32 r17, r17, 0x08
        CMPNEI32 p1, r17, 0
        BR32 p1, .l
        ADDI32 r17, r0, 0               ; 11 文字を比べる
.cmp:   ADDR32 r18, r24, r17
        LOAD8U_32 r18, r18, 0
        LOAD8U_32 r19, r17, name83
        CMPNER32 p1, r18, r19
        BR32 p1, .l
        ADDI32 r17, r17, 1
        CMPLTI32 p1, r17, 11
        BR32 p1, .cmp
        ADDI32 r17, r0, 0               ; 見つけた。32 バイトを ent へ
.cp:    ADDR32 r18, r24, r17
        LOAD32_32 r18, r18, 0
        STORE32_32 r18, r17, ent
        ADDI32 r17, r17, 4
        CMPLTI32 p1, r17, 32
        BR32 p1, .cp
        ADDI32 r16, r0, 1
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; f_open()：ent のファイルを最初から読む準備
f_open:
        LOAD16U_32 r16, r0, ent + 26    ; 最初のクラスタ（下位）
        LOAD16U_32 r17, r0, ent + 20    ; 上位（FAT32 だけ）
        LOAD32_32 r18, r0, fs_type
        CMPEQI32 p1, r18, 32
        SHLI32 r17, r17, 16
        SEL32 r17, r17, r0, p1
        ORR32 r16, r16, r17
        STORE32_32 r16, r0, f_clus
        LOAD32_32 r16, r0, ent + 28
        STORE32_32 r16, r0, f_left
        STORE32_32 r0, r0, f_sec
        STORE32_32 r0, r0, f_err
        RET32

; f_read() → r16 = SECBUF に読んだバイト数（終わりなら 0）
f_read:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD32_32 r16, r0, f_left
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        LOAD32_32 r16, r0, f_sec
        LOAD32_32 r17, r0, spc
        CMPLTUR32 p1, r16, r17
        BR32 p1, .same
        LOAD32_32 r16, r0, f_clus       ; このクラスタは読み終わった
        CALL32 next_clus
        STORE32_32 r16, r0, f_clus
        STORE32_32 r0, r0, f_sec
        CMPEQI32 p1, r16, 0
        BR32 p1, .short
.same:  LOAD32_32 r16, r0, f_clus
        CMPLTUI32 p1, r16, 2
        BR32 p1, .short
        CALL32 clus_lba
        LOAD32_32 r17, r0, f_sec
        ADDR32 r16, r16, r17
        ADDI32 r17, r17, 1
        STORE32_32 r17, r0, f_sec
        ADDI32 r17, r0, SECBUF
        CALL32 bios_sd_read
        CMPNEI32 p1, r16, 0
        BR32 p1, .short
        LOAD32_32 r16, r0, f_left       ; 512 バイトか残り全部の少ない方
        CMPLTUI32 p1, r16, 512
        ADDI32 r17, r0, 512
        SEL32 r16, r16, r17, p1
        LOAD32_32 r17, r0, f_left
        SUBR32 r17, r17, r16
        STORE32_32 r17, r0, f_left
        JMP32 .ret
.short: ADDI32 r16, r0, 1               ; ファイルの大きさより先にクラスタが終わった・読めなかった
        STORE32_32 r16, r0, f_err
.end:   ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; ==================================================================
; 表示の小道具
; ==================================================================

; putdec_w(r16 = 数, r17 = 幅)：右寄せ
putdec_w:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        ADDI32 r18, r0, 1               ; 桁数
        ADDR32 r19, r16, r0
.n:     CMPLTUI32 p1, r19, 10
        BR32 p1, .pad
        DIVUI32 r19, r19, 10
        ADDI32 r18, r18, 1
        JMP32 .n
.pad:   SUBR32 r17, r17, r18
        STORE32_32 r17, r0, tmp
.sp:    LOAD32_32 r17, r0, tmp
        CMPLTI32 p1, r17, 1
        BR32 p1, .num
        ADDI32 r17, r17, -1
        STORE32_32 r17, r0, tmp
        ADDI32 r16, r0, ' '
        CALL32 bios_putc
        JMP32 .sp
.num:   ADDR32 r16, r24, r0
        CALL32 bios_putdec
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; put2(r16)：2 桁（0 埋め）
put2:
        ADDI32 r17, r0, 2
        CMPLTUI32 p1, r16, 10
        BR32 p1, .z
        JMP32 putdec_w
.z:     ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r16, sp, 4
        ADDI32 r16, r0, '0'
        CALL32 bios_putc
        LOAD32_32 r16, sp, 4
        CALL32 bios_putdec
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; putn(r16 = 文字列, r17 = 文字数)：決まった数だけ出す
putn:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r16, r0
        ADDR32 r25, r16, r17
.l:     CMPGEUR32 p1, r24, r25
        BR32 p1, .e
        LOAD8U_32 r16, r24, 0
        CALL32 bios_putc
        ADDI32 r24, r24, 1
        JMP32 .l
.e:     LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; ==================================================================
; 組み込みのコマンド（r16 = 引数）
; ==================================================================
commands:
        .word c_cls, cmd_cls
        .word c_color, cmd_color
        .word c_dir, cmd_dir
        .word c_echo, cmd_echo
        .word c_help, cmd_help
        .word c_led, cmd_led
        .word c_mem, cmd_mem
        .word c_reboot, cmd_reboot
        .word c_shutdown, cmd_shutdown
        .word c_time, cmd_time
        .word c_type, cmd_type
        .word c_ver, cmd_ver
        .word c_vol, cmd_vol
        .word 0, 0

cmd_help:
        ADDI32 r16, r0, s_help
        JMP32 bios_puts
cmd_ver:
        ADDI32 r16, r0, s_ver
        JMP32 bios_puts
cmd_reboot:
        JMP32 reset
cmd_cls:
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, quiet
        JMP32 bios_cls

cmd_echo:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 bios_puts
        ADDI32 r16, r0, 10
        CALL32 bios_putc
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; VOL：ボリュームラベルとシリアル番号
cmd_vol:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 need_fs
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        CALL32 show_vol
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

show_vol:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        ADDI32 r16, r0, s_vol1
        CALL32 bios_puts
        ADDI32 r16, r0, vol_label
        CALL32 bios_puts
        ADDI32 r16, r0, s_vol2
        CALL32 bios_puts
        LOAD32_32 r16, r0, fs_serial    ; XXXX-XXXX
        SHRI32 r16, r16, 16
        CALL32 puthex4
        ADDI32 r16, r0, '-'
        CALL32 bios_putc
        LOAD32_32 r16, r0, fs_serial
        CALL32 puthex4
        ADDI32 r16, r0, 10
        CALL32 bios_putc
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; puthex4(r16)：下位 16bit を 16 進 4 桁
puthex4:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        SHLI32 r24, r16, 16
        ADDI32 r25, r0, 4
.h:     SHRI32 r16, r24, 28
        CMPLTUI32 p1, r16, 10
        ADDI32 r17, r16, '0'
        ADDI32 r18, r16, 'A' - 10
        SEL32 r16, r17, r18, p1
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

; DIR：ルートディレクトリの一覧
cmd_dir:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        CALL32 need_fs
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        CALL32 show_vol
        ADDI32 r16, r0, s_dirof
        CALL32 bios_puts
        ADDI32 r25, r0, 0               ; ファイルの数
        ADDI32 r26, r0, 0               ; 合計の大きさ
        CALL32 dir_open
.l:     CALL32 dir_next
        CMPEQI32 p1, r16, 0
        BR32 p1, .sum
        ADDR32 r24, r16, r0
        LOAD8U_32 r17, r24, 11
        ANDI32 r17, r17, 0x0A           ; ボリュームラベルと隠しファイルは出さない
        CMPNEI32 p1, r17, 0
        BR32 p1, .l
        ADDR32 r16, r24, r0             ; 名前 8 文字、空白、拡張子 3 文字
        ADDI32 r17, r0, 8
        CALL32 putn
        ADDI32 r16, r0, ' '
        CALL32 bios_putc
        ADDI32 r16, r24, 8
        ADDI32 r17, r0, 3
        CALL32 putn
        LOAD8U_32 r17, r24, 11
        ANDI32 r17, r17, 0x10
        CMPEQI32 p1, r17, 0
        BR32 p1, .size
        ADDI32 r16, r0, s_dirtag        ; ディレクトリ
        CALL32 bios_puts
        JMP32 .date
.size:  LOAD32_32 r16, r24, 28
        ADDR32 r26, r26, r16
        ADDI32 r17, r0, 10
        CALL32 putdec_w
        ADDI32 r16, r0, ' '
        CALL32 bios_putc
.date:  LOAD16U_32 r16, r24, 24         ; 日付：月-日-年
        SHRI32 r16, r16, 5
        ANDI32 r16, r16, 15
        CALL32 put2
        ADDI32 r16, r0, '-'
        CALL32 bios_putc
        LOAD16U_32 r16, r24, 24
        ANDI32 r16, r16, 31
        CALL32 put2
        ADDI32 r16, r0, '-'
        CALL32 bios_putc
        LOAD16U_32 r16, r24, 24
        SHRI32 r16, r16, 9
        ADDI32 r16, r16, 1980
        REMUI32 r16, r16, 100
        CALL32 put2
        ADDI32 r16, r0, s_sp2
        CALL32 bios_puts
        LOAD16U_32 r16, r24, 22         ; 時刻：12 時間で a / p
        SHRI32 r16, r16, 11
        REMUI32 r17, r16, 12
        CMPEQI32 p1, r17, 0
        ADDI32 r18, r0, 12
        SEL32 r16, r18, r17, p1
        ADDI32 r17, r0, 2
        CALL32 putdec_w
        ADDI32 r16, r0, ':'
        CALL32 bios_putc
        LOAD16U_32 r16, r24, 22
        SHRI32 r16, r16, 5
        ANDI32 r16, r16, 63
        CALL32 put2
        LOAD16U_32 r16, r24, 22
        SHRI32 r16, r16, 11
        CMPLTUI32 p1, r16, 12
        ADDI32 r17, r0, 'a'
        ADDI32 r18, r0, 'p'
        SEL32 r16, r17, r18, p1
        CALL32 bios_putc
        ADDI32 r16, r0, 10
        CALL32 bios_putc
        ADDI32 r25, r25, 1
        JMP32 .l
.sum:   ADDR32 r16, r25, r0             ; "    n file(s)     合計 bytes"
        ADDI32 r17, r0, 9
        CALL32 putdec_w
        ADDI32 r16, r0, s_files
        CALL32 bios_puts
        ADDR32 r16, r26, r0
        ADDI32 r17, r0, 14
        CALL32 putdec_w
        ADDI32 r16, r0, s_bytes2
        CALL32 bios_puts
        CALL32 count_free               ; 空き
        CMPEQI32 p1, r16, -1
        BR32 p1, .ret
        LOAD32_32 r17, r0, spc
        SHLI32 r17, r17, 9              ; 1 クラスタのバイト数
        MULHUR32 r18, r16, r17          ; 4GB を超えるなら KB で出す
        CMPNEI32 p1, r18, 0
        BR32 p1, .kb
        MULR32 r16, r16, r17
        ADDI32 r17, r0, 28
        CALL32 putdec_w
        ADDI32 r16, r0, s_free
        CALL32 bios_puts
        JMP32 .ret
.kb:    SHRI32 r17, r17, 10
        MULR32 r16, r16, r17
        ADDI32 r17, r0, 28
        CALL32 putdec_w
        ADDI32 r16, r0, s_freekb
        CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; count_free() → r16 = 空きクラスタ数（わからなければ −1）。FAT16 は FAT を数える（一度数えたら覚えておく）
count_free:
        LOAD32_32 r16, r0, fs_free
        CMPNEI32 p1, r16, -1
        BR32 p1, .have
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p1, r17, 16
        BR32 p1, .scan
.have:  RET32
.scan:  ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        ADDI32 r24, r0, 2               ; クラスタ 2 から
        LOAD32_32 r25, r0, nclus
        ADDI32 r25, r25, 2
        ADDI32 r26, r0, 0
.l:     CMPGEUR32 p1, r24, r25
        BR32 p1, .done
        ADDR32 r16, r24, r0
        CALL32 fat_get
        CMPEQI32 p1, r16, 0
        ADDI32 r17, r26, 1
        SEL32 r26, r17, r26, p1
        ADDI32 r24, r24, 1
        JMP32 .l
.done:  STORE32_32 r26, r0, fs_free
        ADDR32 r16, r26, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; TYPE ファイル名：中身を出す（Ctrl-Z で終わり）
cmd_type:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .missing
        CALL32 to83
        CMPEQI32 p1, r16, 0
        BR32 p1, .notfound
        CALL32 need_fs
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        BR32 p1, .notfound
        LOAD8U_32 r16, r0, ent + 11
        ANDI32 r16, r16, 0x10
        CMPNEI32 p1, r16, 0
        BR32 p1, .denied
        CALL32 f_open
        ADDI32 r24, r0, 10              ; 最後に出した文字
.rd:    CALL32 f_read
        CMPEQI32 p1, r16, 0
        BR32 p1, .eof
        ADDI32 r17, r0, SECBUF
        ADDR32 r18, r17, r16
        STORE32_32 r18, r0, tmp
        STORE32_32 r17, r0, tmp2
.c:     LOAD32_32 r17, r0, tmp2
        LOAD32_32 r18, r0, tmp
        CMPGEUR32 p1, r17, r18
        BR32 p1, .rd
        LOAD8U_32 r16, r17, 0
        ADDI32 r17, r17, 1
        STORE32_32 r17, r0, tmp2
        CMPEQI32 p1, r16, 0x1A          ; Ctrl-Z
        BR32 p1, .eof
        CMPEQI32 p1, r16, 13            ; \r は捨てる（\n で改行）
        BR32 p1, .c
        ADDR32 r24, r16, r0
        CMPEQI32 p1, r16, 10
        BR32 p1, .nl
        CALL32 bios_putg
        JMP32 .c
.nl:    CALL32 bios_putc
        JMP32 .c
.eof:   CMPEQI32 p1, r24, 10            ; 最後が改行でなければ改行する
        BR32 p1, .err
        ADDI32 r16, r0, 10
        CALL32 bios_putc
.err:   LOAD32_32 r16, r0, f_err
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r16, r0, s_readerr
        JMP32 .say
.missing:
        ADDI32 r16, r0, s_missing
        JMP32 .say
.denied:
        ADDI32 r16, r0, s_denied
        JMP32 .say
.notfound:
        ADDI32 r16, r0, s_notfound
.say:   CALL32 bios_puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

cmd_mem:
        ADDI32 r16, r0, s_mem
        JMP32 bios_puts

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
        REMUI32 r16, r24, 100
        CALL32 put2
        ADDI32 r16, r0, s_sec
        CALL32 bios_puts
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
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
        CMPEQI32 p1, r17, 0
        CMPEQI32 p2, r17, ' '
        BR32 p2, .fine
        BR32 p1, .fine
        ADDI32 r16, r0, -1
        RET32
.fine:  ADDR32 r16, r19, r0
        RET32

; COLOR xy：x = 背景色、y = 文字色（16 進）。画面全体の色を変える。引数なしで 07 に戻す
cmd_color:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .reset
        CALL32 hex2
        CMPLTI32 p1, r16, 0
        BR32 p1, .usage
        JMP32 .set
.reset: ADDI32 r16, r0, 0x07
.set:   STORE32_32 r16, r0, ATTR
        ADDI32 r17, r0, VRAM + 1        ; 色のバイトだけ全部書き換える
        ADDI32 r18, r0, VRAM + COLS * ROWS * 2
.l:     STORE8_32 r16, r17, 0
        ADDI32 r17, r17, 2
        CMPLTUR32 p1, r17, r18
        BR32 p1, .l
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
        CALL32 hex2
        CMPLTI32 p1, r16, 0
        BR32 p1, .usage
        STORE32_32 r16, r0, LED
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

s_banner:   .asciz "MyDOS Version 2.0\n(C)Copyright MyCPU Project 2026.\n"
s_prompt:   .asciz "C:\\>"
s_bad:      .asciz "Bad command or file name\n"
s_ver:      .asciz "\nMyDOS Version 2.0 (MyCPU-32, FAT16/FAT32 read-only)\n"
s_help:     .ascii "CLS       Clears the screen.\n"
            .ascii "COLOR xy  Sets colors (x = background, y = text, hex). COLOR alone resets.\n"
            .ascii "DIR       Displays the files on drive C: (SD card).\n"
            .ascii "ECHO      Displays a message.\n"
            .ascii "LED xx    Turns the board LEDs on/off (hex).\n"
            .ascii "MEM       Displays the memory map.\n"
            .ascii "REBOOT    Restarts the computer.\n"
            .ascii "SHUTDOWN  Halts the CPU.\n"
            .ascii "TIME      Displays the time since boot.\n"
            .ascii "TYPE      Displays the contents of a text file.\n"
            .ascii "VER       Displays the MyDOS version.\n"
            .ascii "VOL       Displays the volume label and serial number.\n"
            .asciz "To run a program, type its name (.EXE, .COM or .BAT on drive C:).\n"
s_vol1:     .asciz " Volume in drive C is "
s_vol2:     .asciz "\n Volume Serial Number is "
s_dirof:    .asciz " Directory of C:\\\n\n"
s_dirtag:   .asciz "    <DIR>  "
s_sp2:      .asciz "  "
s_files:    .asciz " file(s)"
s_bytes2:   .asciz " bytes\n"
s_free:     .asciz " bytes free\n"
s_freekb:   .asciz " KB free\n"
s_notready: .asciz "Not ready reading drive C\n"
s_notfound: .asciz "File not found\n"
s_missing:  .asciz "Required parameter missing\n"
s_denied:   .asciz "Access denied\n"
s_readerr:  .asciz "Read error reading drive C\n"
s_toobig2:  .asciz "Program too big to fit in memory\n"
s_badexe:   .asciz "Invalid EXE file\n"
s_batbig:   .asciz "Batch file too large\n"
s_mem:      .ascii "\n   32768 bytes total memory\n"
            .ascii "   16384 bytes for programs (0x23000-0x26FFF)\n"
            .asciz "   12288 bytes used by MyDOS (0x20000-0x22FFF)\n"
s_uptime:   .asciz "Uptime: "
s_sec:      .asciz " seconds\n"
s_color_usage: .asciz "Usage: COLOR xy  (x = background, y = text, 0-F)\n"
s_led_usage:   .asciz "Usage: LED xx  (hex, lower 6 bits)\n"
s_safe:     .asciz "\n\n          It's now safe to turn off your computer.\n"
s_autoexec: .asciz "AUTOEXEC.BAT"
x_exe:      .ascii "EXE"
x_com:      .ascii "COM"
x_bat:      .ascii "BAT"
exts:       .ascii "EXE\0COM\0BAT\0\0"
c_cls:      .asciz "CLS"
c_color:    .asciz "COLOR"
c_dir:      .asciz "DIR"
c_echo:     .asciz "ECHO"
c_help:     .asciz "HELP"
c_led:      .asciz "LED"
c_mem:      .asciz "MEM"
c_reboot:   .asciz "REBOOT"
c_shutdown: .asciz "SHUTDOWN"
c_time:     .asciz "TIME"
c_type:     .asciz "TYPE"
c_ver:      .asciz "VER"
c_vol:      .asciz "VOL"
        .align 4
os_data_end:                            ; ここから先は 0 で始まる変数（ROM には置かない）
        .dephase
os_image_end:
        .phase os_data_end
fs_ok:      .reserve 4
fs_type:    .reserve 4
part_lba:   .reserve 4
fat_lba:    .reserve 4
root_lba:   .reserve 4
root_secs:  .reserve 4
root_clus:  .reserve 4
data_lba:   .reserve 4
spc:        .reserve 4
nclus:      .reserve 4
fs_serial:  .reserve 4
fs_free:    .reserve 4
fat_cache:  .reserve 4
d_lba:      .reserve 4
d_left:     .reserve 4
d_clus:     .reserve 4
d_idx:      .reserve 4
d_end:      .reserve 4
f_clus:     .reserve 4
f_left:     .reserve 4
f_sec:      .reserve 4
f_err:      .reserve 4
bat_ptr:    .reserve 4
bat_end:    .reserve 4
quiet:      .reserve 4
saved_sp:   .reserve 4
tmp:        .reserve 4
tmp2:       .reserve 4
args:       .reserve 4
ent:        .reserve 32
name83:     .reserve 12
vol_label:  .reserve 12
linebuf:    .reserve 128
cmdbuf:     .reserve 80
os_end:
        .dephase
