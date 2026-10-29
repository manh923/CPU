; mydos.sys.asm — MyDOS 本体（SD カードの MYDOS.SYS。BIOS がこれを 0x20000 に読み込んで飛ぶ）
;
; ・ドライブ C: は SD カードの FAT16 / FAT32（ルートディレクトリ）。読み書きできる
; ・組み込みのコマンド：CLS COLOR COPY DEL DIR ECHO HELP LED MEM REBOOT REN SHUTDOWN TIME TYPE VER VOL
;   それ以外は .EXE → .COM → .BAT の順に探して実行する。起動時に AUTOEXEC.BAT を実行する
; ・「コマンド > ファイル」「コマンド >> ファイル」で、画面に出るものをファイルへ（リダイレクト）
; ・.EXE・.COM は 0x26000 に読み込んで、ユーザーモードで実行する。OS を呼ぶのは SYSCALL だけ。
;   例外を起こしたら "Program terminated" を出して C:\> に戻る
;     .EXE：先頭 16 バイトがヘッダ（'MZ'、ヘッダの大きさ 2 バイト、読み込む番地・開始番地・本体の大きさ 各 4 バイト）。
;       ヘッダの大きさの欄が 0x8010 なら区切りのある .EXE（AS -lib が作る。使う関数だけ入れたもの）：
;       本体は「番地・長さ（4 バイトずつ）・中身」の並び。読み込む番地はいちばん小さい番地
;     .COM：ヘッダなし。0x26000 に置いて 0x26000 から実行
;   プログラムは r16 に引数の文字列を受け取り、RET32 か SYSCALL 0（終了）で C:\> に戻る
;
; SYSCALL（r23 = 番号、引数 r16〜r19、戻り値 r16）。BIOS が 1〜10 を、MyDOS が 0 と 0x10〜を登録し、
; 画面に出す 1・2・6・7・8 はリダイレクトできるように MyDOS の版に差し替える
;    0 終了              1 putc(文字)          2 puts(文字列)       3 getc() → 文字
;    4 getline(置き場所, 最大) → 長さ           5 cls()              6 putdec(数)        7 puthex(数)
;    8 putg(文字)        9 setattr(色) → 前の色                     10 kbhit() → キーが来ていれば 1
;   16 open(名前, モード) → ハンドル（モード 0 = 読む、1 = 新しく書く、2 = 後ろに足す）
;   17 close(ハンドル)   18 read(ハンドル, 置き場所, 長さ) → 読んだ長さ（0 で終わり）
;   19 write(ハンドル, データ, 長さ) → 書いた長さ          20 delete(名前)     21 rename(前の名前, 新しい名前)
;   22 seek(ハンドル, 位置, 基準) → 新しい位置（基準 0 = 先頭、1 = 今の位置、2 = 終わり。書くファイルは終わりだけ）
;   エラーは負の数：-1 番号がない・ハンドルが違う、-2 ファイルがない、-3 開きすぎ、-4 空きがない、
;   -5 できない（ディレクトリ・読み出し専用・同じ名前がある）、-6 名前が正しくない、-7 カードが読めない
; 呼び出し規約は 8 章どおり：r16〜r23 は壊れてよい、r24〜r31 は保存する。

BIOS_PUTC    = 0x10                     ; BIOS の入口（ROM の決まった番地）
BIOS_PUTS    = 0x18
BIOS_GETC    = 0x20
BIOS_GETLINE = 0x28
BIOS_CLS     = 0x30
BIOS_PUTDEC  = 0x38
BIOS_PUTHEX  = 0x40
BIOS_REBOOT  = 0x48
BIOS_PUTG    = 0x50
BIOS_SDINIT  = 0x58
BIOS_SDREAD  = 0x60
BIOS_SDWRITE = 0x68
BIOS_SETATTR = 0x78
TIMER_COUNT  = 0x00010010
LED          = 0x00010020
VRAM         = 0x00018000
COLS         = 160
ROWS         = 45
BDA          = 0x0002B000               ; BIOS の変数
ATTR         = BDA + 8
SD_TYPE      = BDA + 16
USER_FAULT   = BDA + 24
SDRAM_KB     = BDA + 28                 ; BIOS が調べた SDRAM の大きさ（KB）
SDRAM        = 0x01000000               ; SDRAM の先頭（.EXE をここに読み込んでもよい）
VEC          = 0x0002B100               ; SYSCALL の表
SECBUF       = 0x0002B200               ; セクタの置き場（1 つだけ覚えておく。書いたら後でまとめて書き戻す）
FATBUF       = 0x0002B400               ; FAT のセクタの置き場（同じく）
BATBUF       = 0x0002B600               ; .BAT を読み込む置き場
BATMAX       = 0x400
STACK_TOP    = 0x0002C000
TPA          = 0x00026000               ; .EXE・.COM を読み込む場所
TPA_END      = 0x0002B000
COPYBUF      = TPA                      ; COPY・TYPE の作業用（プログラムが動いていないときは空いている）
NFILES       = 4                        ; 同時に開けるファイルの数
FAT_DATE     = (2026 - 1980) << 9 | 1 << 5 | 1   ; 時計がないので、書いたファイルの日付は 2026-01-01 にする
SYS_EXIT     = 0

; ハンドル 1 つ（32 バイト）の中身
H_MODE  = 0                             ; 0 = 空き、1 = 読む、2 = 書く
H_FIRST = 4                             ; 最初のクラスタ（0 なら中身なし）
H_SIZE  = 8
H_POS   = 12                            ; 次に読み書きする位置
H_CLUS  = 16                            ; 今いるクラスタ（0 ならまだ）
H_CIDX  = 20                            ; そのクラスタが何番目か
H_DLBA  = 24                            ; ディレクトリの項目があるセクタ
H_DOFF  = 28                            ; そのセクタの中の位置

        .org 0x20000
dos_start:
        ADDI32 sp, r0, STACK_TOP
        ADDI32 r16, r0, bss_start       ; 変数を 0 にする
        ADDI32 r17, r0, bss_end
.z:     STORE32_32 r0, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .z
        ADDI32 r16, r0, -1
        STORE32_32 r16, r0, redir_h
        ADDI32 r16, r0, dos_vectors     ; SYSCALL の表に MyDOS の機能を登録
.v:     LOAD32_32 r17, r16, 0
        CMPLTI32 p1, r17, 0
        BR32 p1, .vdone
        LOAD32_32 r18, r16, 4
        SHLI32 r17, r17, 2
        STORE32_32 r18, r17, VEC
        ADDI32 r16, r16, 8
        JMP32 .v
.vdone: ADDI32 r16, r0, dos_fault       ; プログラムの例外を受け取る
        STORE32_32 r16, r0, USER_FAULT
        ADDI32 r16, r0, s_banner
        CALL32 puts
        CALL32 fs_mount                 ; カードが読めて AUTOEXEC.BAT があれば実行する
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
        CALL32 putc
.prompt:
        ADDI32 r16, r0, s_prompt
        CALL32 puts
        ADDI32 r16, r0, linebuf
        ADDI32 r17, r0, 72
        CALL32 BIOS_GETLINE
        CALL32 exec_line
        JMP32 shell

        .align 4
dos_vectors:                            ; SYSCALL の表に入れる MyDOS の機能（番号, 番地）
        .word 0, sys_exit
        .word 1, putc
        .word 2, puts
        .word 6, putdec
        .word 7, puthex
        .word 8, putg
        .word 16, f_open
        .word 17, f_close
        .word 18, f_read
        .word 19, f_write
        .word 20, f_delete
        .word 21, f_rename
        .word 22, f_seek
        .word -1

; ==================================================================
; 1 行の実行
; ==================================================================

; exec_line()：linebuf の 1 行を実行する。"> ファイル" "">> ファイル" があれば、画面に出るものをそこへ
exec_line:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDI32 r16, r0, linebuf         ; '>' を探す
.gt:    LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .run
        CMPEQI32 p1, r17, '>'
        BR32 p1, .redir
        ADDI32 r16, r16, 1
        JMP32 .gt
.redir: STORE8_32 r0, r16, 0            ; コマンドはここまで
        ADDI32 r17, r0, 1               ; 1 = 新しく書く
        LOAD8U_32 r18, r16, 1
        CMPNEI32 p1, r18, '>'
        BR32 p1, .name
        ADDI32 r17, r0, 2               ; ">>" は後ろに足す
        ADDI32 r16, r16, 1
.name:  ADDI32 r16, r16, 1
        LOAD8U_32 r18, r16, 0
        CMPEQI32 p1, r18, ' '
        BR32 p1, .name
        CALL32 f_open
        CMPLTI32 p1, r16, 0
        BR32 p1, .rfail
        STORE32_32 r16, r0, redir_h
.run:   CALL32 run_line
        LOAD32_32 r16, r0, redir_h
        CMPLTI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r17, r0, -1
        STORE32_32 r17, r0, redir_h
        CALL32 f_close
        JMP32 .ret
.rfail: ADDI32 r16, r0, s_createerr
        CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; run_line()：コマンドを見分けて実行する
run_line:
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
        BR32 p1, .call
        ADDI32 r24, r24, 8
        JMP32 .find
.call:  LOAD32_32 r17, r24, 4
        LOAD32_32 r16, r0, args
        CALLR32 r17
        JMP32 .ret
.file:  CALL32 run_file                 ; .EXE・.COM・.BAT
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r16, r0, s_bad
        CALL32 puts
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
        ADDI32 r19, r17, -'a'           ; 'a'〜'z' なら大文字に
        CMPLTUI32 p6, r19, 26
        ADDI32 r19, r17, -32
        SEL32 r17, r19, r17, p6
        STORE8_32 r17, r18, 0
        ADDI32 r16, r16, 1
        ADDI32 r18, r18, 1
        JMP32 .w
.end:   STORE8_32 r0, r18, 0
.a:     LOAD8U_32 r17, r16, 0           ; 空白を飛ばす
        CMPNEI32 p1, r17, ' '
        BR32 p1, .done
        ADDI32 r16, r16, 1
        JMP32 .a
.done:  STORE32_32 r16, r0, args
        RET32

; skipsp(r16 = 文字列) → r16 = 空白を飛ばしたところ。r17 を壊す
skipsp:
        LOAD8U_32 r17, r16, 0
        CMPNEI32 p6, r17, ' '
        BR32 p6, .e
        ADDI32 r16, r16, 1
        JMP32 skipsp
.e:     RET32

; cutword(r16 = 文字列) → r16 = 次の語（最初の語の後ろの空白を 0 にして切る）。r17 を壊す
cutword:
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p6, r17, 0
        BR32 p6, .e
        CMPEQI32 p6, r17, ' '
        BR32 p6, .cut
        ADDI32 r16, r16, 1
        JMP32 cutword
.cut:   STORE8_32 r0, r16, 0
        ADDI32 r16, r16, 1
        JMP32 skipsp
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

; to83(r16 = "README.TXT") → name83 に 11 文字の形（"README  TXT"）。r16 = 1 なら成功。r17〜r21 を壊す
to83:
        ADDI32 r17, r0, 0x20202020      ; まず空白で埋める
        STORE32_32 r17, r0, name83
        STORE32_32 r17, r0, name83 + 4
        STORE32_32 r17, r0, name83 + 8
        ADDI32 r18, r0, 0               ; 書く位置
        ADDI32 r20, r0, 8               ; この部分の終わり（名前 8、拡張子 11）
.c:     LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
        CMPEQI32 p1, r17, ' '
        BR32 p1, .end
        CMPNEI32 p1, r17, '.'
        BR32 p1, .ch
        CMPEQI32 p1, r20, 11            ; 2 つ目の '.'
        BR32 p1, .bad
        CMPEQI32 p1, r18, 0             ; 名前が空
        BR32 p1, .bad
        ADDI32 r18, r0, 8
        ADDI32 r20, r0, 11
        ADDI32 r16, r16, 1
        JMP32 .c
.ch:    CMPGEUR32 p1, r18, r20          ; 長すぎる
        BR32 p1, .bad
        CMPLTUI32 p1, r17, '!'          ; 使えない文字
        BR32 p1, .bad
        ADDI32 r19, r0, badchars
.bc:    LOAD8U_32 r21, r19, 0
        CMPEQI32 p1, r21, 0
        BR32 p1, .ok
        CMPEQR32 p1, r21, r17
        BR32 p1, .bad
        ADDI32 r19, r19, 1
        JMP32 .bc
.ok:    ADDI32 r19, r17, -'a'           ; 'a'〜'z' なら大文字に
        CMPLTUI32 p6, r19, 26
        ADDI32 r19, r17, -32
        SEL32 r17, r19, r17, p6
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

; ==================================================================
; ファイルの実行
; ==================================================================

; run_file() → r16 = 1 なら実行した（エラーを出した場合も含む）、0 ならそういうファイルはない
run_file:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDI32 r16, r0, cmdbuf
        CALL32 to83
        CMPEQI32 p1, r16, 0
        BR32 p1, .no
        CALL32 need_fs
        CMPEQI32 p1, r16, 0
        BR32 p1, .yes                   ; カードが読めない（メッセージは出した）
        LOAD8U_32 r16, r0, name83 + 8   ; 拡張子があればその名前で
        CMPEQI32 p1, r16, ' '
        BR32 p1, .noext
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        BR32 p1, .no
        JMP32 .kind
.noext: ADDI32 r24, r0, exts            ; .EXE → .COM → .BAT
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

; ext_is(r16, r17) → 3 文字が同じなら 1。r18〜r20 を壊す
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

; run_prog()：name83 の .EXE・.COM を TPA に読み込んで、ユーザーモードで実行する
run_prog:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        STORE32_32 r28, sp, 20
        ADDI32 r16, r0, 0               ; 読むモードで開く（name83 はもう入っている）
        CALL32 f_open83
        CMPLTI32 p1, r16, 0
        BR32 p1, .ioerr
        ADDR32 r24, r16, r0
        CALL32 h_ptr
        LOAD32_32 r25, r16, H_SIZE
        ADDI32 r16, r0, ent + 8
        ADDI32 r17, r0, x_com
        CALL32 ext_is
        CMPEQI32 p1, r16, 0
        BR32 p1, .exe
        ; .COM：全部 TPA に読んで、TPA から実行
        ADDI32 r17, r0, TPA_END - TPA
        CMPLTUR32 p1, r17, r25
        BR32 p1, .big
        ADDI32 r26, r0, TPA             ; r26 = 開始番地
        ADDI32 r17, r0, TPA
        ADDR32 r18, r25, r0
        JMP32 .load
        ; .EXE：ヘッダ（16 バイト）を読んで確かめ、本体を「読み込む番地」へ直接読む
        ;   読み込む番地は TPA（0x26000〜）か SDRAM（0x1000000〜。BIOS が SDRAM を見つけたときだけ）
.exe:   ADDR32 r16, r24, r0
        ADDI32 r17, r0, exehdr
        ADDI32 r18, r0, 16
        CALL32 f_read
        CMPNEI32 p1, r16, 16
        BR32 p1, .badexe1
        LOAD16U_32 r16, r0, exehdr
        CMPNEI32 p1, r16, 0x5A4D        ; 'M' 'Z'
        BR32 p1, .badexe1
        LOAD16U_32 r17, r0, exehdr + 2  ; ヘッダの大きさ（16。0x8010 なら区切りのある .EXE）
        LOAD32_32 r18, r0, exehdr + 4   ; 読み込む番地
        LOAD32_32 r26, r0, exehdr + 8   ; 開始番地
        LOAD32_32 r19, r0, exehdr + 12  ; 本体の大きさ
        CMPEQI32 p1, r17, 0x8010
        BR32 p1, .seg
        CMPNEI32 p1, r17, 16
        BR32 p1, .badexe1
        ADDI32 r20, r19, 16             ; ヘッダ + 本体 ≦ ファイルの大きさ
        CMPLTUR32 p1, r25, r20
        BR32 p1, .badexe1
        ANDI32 r20, r18, 3              ; 読み込む番地は 4 の倍数
        CMPNEI32 p1, r20, 0
        BR32 p1, .badexe1
        SUBR32 r20, r26, r18            ; 開始番地が本体の中
        CMPGEUR32 p1, r20, r19
        BR32 p1, .badexe1
        ; どこに置くか：TPA の中か、SDRAM の中
        ADDI32 r20, r18, -TPA
        ADDI32 r21, r0, TPA_END - TPA
        CMPLTUR32 p1, r20, r21          ; TPA ≦ 読み込む番地 < TPA_END
        SUBR32 r21, r21, r20            ; 残りの大きさ
        BR32 p1, .fit
        LOAD32_32 r21, r0, SDRAM_KB
        CMPEQI32 p1, r21, 0
        BR32 p1, .big1
        ADDI32 r20, r18, -SDRAM
        SHLI32 r21, r21, 10
        CMPGEUR32 p1, r20, r21          ; SDRAM ≦ 読み込む番地 < SDRAM の終わり
        BR32 p1, .big1
        SUBR32 r21, r21, r20
.fit:   CMPLTUR32 p1, r21, r19          ; 本体が入りきるか
        BR32 p1, .big1
        ADDR32 r17, r18, r0
        ADDR32 r18, r19, r0
.load:  ADDR32 r25, r18, r0             ; r25 = 読む大きさ
        STORE32_32 r17, r0, prog_base
        ADDR32 r16, r24, r0
        CALL32 f_read
        ADDR32 r20, r16, r0
        ADDR32 r16, r24, r0
        CALL32 f_close
        CMPNER32 p1, r20, r25
        BR32 p1, .ioerr
        JMP32 .go
        ; 区切りのある .EXE：場所（TPA か SDRAM）を読み込む番地で決め、区切りを 1 つずつその番地へ読む
        ;   r27〜r28 = 場所の範囲、r25 = 本体の残り
.seg:   ADDI32 r20, r19, 16             ; ヘッダ + 本体 ≦ ファイルの大きさ
        CMPLTUR32 p1, r25, r20
        BR32 p1, .badexe1
        ADDI32 r27, r0, TPA
        ADDI32 r28, r0, TPA_END
        CMPLTUR32 p1, r18, r27
        BR32 p1, .sdram
        CMPLTUR32 p1, r18, r28
        BR32 p1, .sgo
.sdram: LOAD32_32 r21, r0, SDRAM_KB
        CMPEQI32 p1, r21, 0
        BR32 p1, .big1
        ADDI32 r27, r0, SDRAM
        SHLI32 r21, r21, 10
        ADDI32 r28, r21, SDRAM
        CMPLTUR32 p1, r18, r27
        BR32 p1, .big1
        CMPGEUR32 p1, r18, r28
        BR32 p1, .big1
.sgo:   STORE32_32 r18, r0, prog_base
        ADDR32 r25, r19, r0
.sl:    CMPEQI32 p1, r25, 0
        BR32 p1, .sdone
        CMPLTUI32 p1, r25, 8
        BR32 p1, .badexe1
        ADDR32 r16, r24, r0             ; 番地と長さ（exehdr に）
        ADDI32 r17, r0, exehdr
        ADDI32 r18, r0, 8
        CALL32 f_read
        CMPNEI32 p1, r16, 8
        BR32 p1, .badexe1
        ADDI32 r25, r25, -8
        LOAD32_32 r17, r0, exehdr       ; 番地：場所の中（4 の倍数でなくてよい）
        LOAD32_32 r18, r0, exehdr + 4   ; 長さ：本体の残りまで、場所の終わりまで
        CMPLTUR32 p1, r25, r18
        BR32 p1, .badexe1
        CMPLTUR32 p1, r17, r27
        BR32 p1, .big1
        CMPGEUR32 p1, r17, r28
        BR32 p1, .big1
        SUBR32 r20, r28, r17
        CMPLTUR32 p1, r20, r18
        BR32 p1, .big1
        SUBR32 r25, r25, r18
        ADDR32 r16, r24, r0
        CALL32 f_read
        LOAD32_32 r17, r0, exehdr + 4
        CMPNER32 p1, r16, r17
        BR32 p1, .badexe1
        JMP32 .sl
.sdone: ADDR32 r16, r24, r0
        CALL32 f_close
        CMPLTUR32 p1, r26, r27          ; 開始番地が場所の中
        BR32 p1, .badexe
        CMPGEUR32 p1, r26, r28
        BR32 p1, .badexe
.go:    LOAD32_32 r16, r0, ATTR         ; 色を覚えておいて、終わったら戻す
        STORE32_32 r16, r0, saved_attr
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, running
        STORE32_32 sp, r0, saved_sp     ; 終了（SYSCALL 0）・例外のときは .back へ
        ADDI32 lr, r0, exit_stub        ; RET32 で戻ってきたら SYSCALL 0
        LOAD32_32 r16, r0, prog_base    ; SDRAM のプログラムは、スタックも SDRAM の末尾に
        CMPLTUI32 p1, r16, SDRAM
        BR32 p1, .stk
        LOAD32_32 r16, r0, SDRAM_KB
        SHLI32 r16, r16, 10
        ADDI32 sp, r16, SDRAM
.stk:   ADDR32 epc, r26, r0
        ADDI32 status, r0, 4            ; ERET で「例外の直前の特権 = ユーザー」に戻る → ユーザーモード
        LOAD32_32 r16, r0, args
        ERET
.back:                                  ; 終了・例外のときはここへ戻る（ここからカーネルモード）
        LOAD32_32 sp, r0, saved_sp
        ADDI32 status, r0, 0
        STORE32_32 r0, r0, running
        CALL32 close_all                ; 開けたままのファイルを閉じる
        LOAD32_32 r16, r0, saved_attr
        CALL32 BIOS_SETATTR
        JMP32 .ret
.big1:
.big:   ADDR32 r16, r24, r0
        CALL32 f_close
        ADDI32 r16, r0, s_toobig
        JMP32 .say
.badexe1:
        ADDR32 r16, r24, r0
        CALL32 f_close
.badexe:
        ADDI32 r16, r0, s_badexe
        JMP32 .say
.ioerr: ADDI32 r16, r0, s_readerr
.say:   CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        LOAD32_32 r28, sp, 20
        ADDI32 sp, sp, 24
        RET32

exit_stub:                              ; プログラムが RET32 で戻るとここ（まだユーザーモード）
        ADDI32 r23, r0, SYS_EXIT
        SYSCALL

; SYSCALL 0：プログラムの終わり
sys_exit:
        LOAD32_32 r17, r0, running
        CMPEQI32 p1, r17, 0
        BR32 p1, .no
        JMP32 run_prog.back
.no:    ADDI32 r16, r0, -1
        RET32

; ユーザーモードのプログラムが例外を起こした（BIOS がここへ飛ぶ）
dos_fault:
        LOAD32_32 r16, r0, running
        CMPEQI32 p1, r16, 0
        BR32 p1, .halt
        ADDI32 r16, r0, s_term
        CALL32 puts
        ADDR32 r16, cause, r0           ; 理由
        ADDI32 r17, r0, s_fault_other
        CMPEQI32 p1, r16, 1
        ADDI32 r18, r0, s_fault_align
        SEL32 r17, r18, r17, p1
        CMPEQI32 p1, r16, 2
        ADDI32 r18, r0, s_fault_priv
        SEL32 r17, r18, r17, p1
        CMPEQI32 p1, r16, 4
        ADDI32 r18, r0, s_fault_div
        SEL32 r17, r18, r17, p1
        ADDR32 r16, r17, r0
        CALL32 puts
        ADDI32 r16, r0, s_at
        CALL32 puts
        ADDR32 r16, epc, r0
        CALL32 puthex
        ADDI32 r16, r0, 10
        CALL32 putc
        JMP32 run_prog.back
.halt:  HLT

; run_batch()：name83 の .BAT を 1 行ずつ実行する。行の中の %1〜%9 は、.BAT に渡した引数の 1〜9 番目の語に置き換える。
; 途中で別の .BAT を実行すると、そちらへ移って元には戻らない（MS-DOS と同じ）
run_batch:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r16, r0, args         ; 引数を batargs へ写す（linebuf は 1 行ごとに書き換わるので）
        ADDI32 r17, r0, batargs
        ADDI32 r18, r0, batargs + 127
        CMPEQI32 p1, r16, 0
        BR32 p1, .acp
.ac:    LOAD8U_32 r19, r16, 0
        CMPEQI32 p1, r19, 0
        BR32 p1, .acp
        CMPGEUR32 p1, r17, r18
        BR32 p1, .acp
        STORE8_32 r19, r17, 0
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 1
        JMP32 .ac
.acp:   STORE8_32 r0, r17, 0
        ADDI32 r16, r0, 0
        CALL32 f_open83
        CMPLTI32 p1, r16, 0
        BR32 p1, .ret
        ADDR32 r24, r16, r0
        ADDI32 r17, r0, BATBUF
        ADDI32 r18, r0, BATMAX
        CALL32 f_read
        ADDR32 r17, r16, r0
        ADDR32 r16, r24, r0
        ADDR32 r24, r17, r0
        CALL32 f_close
        CMPLTI32 p1, r24, 0
        BR32 p1, .ret
        ADDI32 r16, r24, BATBUF
        STORE32_32 r16, r0, bat_end
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
        CMPNEI32 p1, r19, '%'           ; %1〜%9
        BR32 p1, .put
        CMPGEUR32 p1, r16, r17
        BR32 p1, .put
        LOAD8U_32 r21, r16, 0
        ADDI32 r21, r21, -'1'
        CMPGEUI32 p1, r21, 9
        BR32 p1, .put
        ADDI32 r16, r16, 1
        ADDI32 r21, r21, 1
        CALL32 bat_arg
        JMP32 .c
.put:   CMPGEUR32 p1, r18, r20
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
        CALL32 putc
        ADDI32 r16, r0, s_prompt
        CALL32 puts
        ADDI32 r16, r0, linebuf
        CALL32 puts
        ADDI32 r16, r0, 10
        CALL32 putc
.exec:  CALL32 exec_line
        JMP32 .line
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; bat_arg(r21 = n)：batargs の n 番目の語を r18 へ足す（r20 まで）。r18 を進める。r19・r21・r22 を壊す
bat_arg:
        ADDI32 r22, r0, batargs
.sp:    LOAD8U_32 r19, r22, 0           ; 空白を飛ばす
        CMPNEI32 p1, r19, ' '
        BR32 p1, .word
        ADDI32 r22, r22, 1
        JMP32 .sp
.word:  CMPEQI32 p1, r19, 0
        BR32 p1, .ret
        ADDI32 r21, r21, -1
        CMPEQI32 p1, r21, 0
        BR32 p1, .cp
.skip:  CMPEQI32 p1, r19, 0             ; この語を飛ばす
        BR32 p1, .ret
        CMPEQI32 p1, r19, ' '
        BR32 p1, .sp
        ADDI32 r22, r22, 1
        LOAD8U_32 r19, r22, 0
        JMP32 .skip
.cp:    CMPEQI32 p1, r19, 0
        BR32 p1, .ret
        CMPEQI32 p1, r19, ' '
        BR32 p1, .ret
        CMPGEUR32 p1, r18, r20
        BR32 p1, .ret
        STORE8_32 r19, r18, 0
        ADDI32 r18, r18, 1
        ADDI32 r22, r22, 1
        LOAD8U_32 r19, r22, 0
        JMP32 .cp
.ret:   RET32

; ==================================================================
; 画面への出力（リダイレクト中はファイルへ）
; ==================================================================

; putc(r16)：\n はファイルでは \r\n にする
putc:
        LOAD32_32 r17, r0, redir_h
        CMPLTI32 p6, r17, 0
        BR32 p6, .screen
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        CMPNEI32 p6, r24, 10
        BR32 p6, .one
        ADDI32 r16, r0, 13
        CALL32 putraw
.one:   ADDR32 r16, r24, r0
        CALL32 putraw
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32
.screen:
        JMP32 BIOS_PUTC

; putg(r16)：文字の形のまま（ファイルへはそのまま 1 バイト）
putg:
        LOAD32_32 r17, r0, redir_h
        CMPLTI32 p6, r17, 0
        BR32 p6, .screen
        JMP32 putraw
.screen:
        JMP32 BIOS_PUTG

; putraw(r16)：リダイレクト先のファイルへ 1 バイト
putraw:
        STORE8_32 r16, r0, cbuf
        LOAD32_32 r16, r0, redir_h
        ADDI32 r17, r0, cbuf
        ADDI32 r18, r0, 1
        JMP32 f_write

; puts(r16)
puts:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
.n:     LOAD8U_32 r16, r24, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .e
        CALL32 putc
        ADDI32 r24, r24, 1
        JMP32 .n
.e:     LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; putn(r16 = 文字列, r17 = 文字数)
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
        CALL32 putc
        ADDI32 r24, r24, 1
        JMP32 .l
.e:     LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; putdec(r16)：符号なし 10 進
putdec:
        ADDI32 r17, r0, 0
        JMP32 putdec_w

; putdec_w(r16 = 数, r17 = 幅)：右寄せ
putdec_w:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 fmtdec
        CALL32 puts
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; fmtdec(r16 = 数, r17 = 幅) → r16 = numbuf の中の 10 進の文字列（右寄せ）。r17〜r19 を壊す
fmtdec:
        ADDI32 r18, r0, numbuf + 11     ; 後ろから数字を置く
        STORE8_32 r0, r18, 0
.d:     ADDI32 r18, r18, -1
        REMUI32 r19, r16, 10
        ADDI32 r19, r19, '0'
        STORE8_32 r19, r18, 0
        DIVUI32 r16, r16, 10
        ADDI32 r17, r17, -1
        CMPNEI32 p1, r16, 0
        BR32 p1, .d
        ADDI32 r19, r0, ' '
.pad:   CMPLTI32 p1, r17, 1
        BR32 p1, .out
        ADDI32 r18, r18, -1
        STORE8_32 r19, r18, 0
        ADDI32 r17, r17, -1
        JMP32 .pad
.out:   ADDR32 r16, r18, r0
        RET32

; put2(r16)：2 桁（0 埋め）。100 を足して 3 桁にし、先頭の 1 を飛ばす
put2:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        ADDI32 r16, r16, 100
        ADDI32 r17, r0, 0
        CALL32 fmtdec
        ADDI32 r16, r16, 1
        CALL32 puts
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; puthex(r16)：16 進 8 桁
puthex:
        ADDI32 r17, r0, 8
; puthexn(r16 = 数, r17 = 桁数)
puthexn:
        ADDI32 r18, r0, numbuf + 11
        STORE8_32 r0, r18, 0
.h:     ADDI32 r18, r18, -1
        ANDI32 r19, r16, 15
        CMPLTUI32 p1, r19, 10
        ADDI32 r20, r19, '0'
        ADDI32 r19, r19, 'A' - 10
        SEL32 r19, r20, r19, p1
        STORE8_32 r19, r18, 0
        SHRI32 r16, r16, 4
        ADDI32 r17, r17, -1
        CMPNEI32 p1, r17, 0
        BR32 p1, .h
        ADDR32 r16, r18, r0
        JMP32 puts

; ==================================================================
; FAT（FAT16 / FAT32、ルートディレクトリ、読み書き）
; ==================================================================

; rd16 / rd32(r16 = 番地) → r16。整列していない番地からも読める（BPB 用）。r17, r18 を壊す
rd16:
        LOAD8U_32 r17, r16, 1
        LOAD8U_32 r16, r16, 0
        SHLI32 r17, r17, 8
        ORR32 r16, r16, r17
        RET32
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
        CMPNEI32 p1, r16, 0
        BR32 p1, .ok2
        ADDI32 r16, r0, s_notready
        CALL32 puts
        ADDI32 r16, r0, 0
.ok2:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
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
        ADDI32 r16, r0, -1              ; 置き場所はどれも空
        STORE32_32 r16, r0, sb_lba
        STORE32_32 r16, r0, fc_sec
        STORE32_32 r0, r0, sb_dirty
        STORE32_32 r0, r0, fc_dirty
        LOAD32_32 r16, r0, SD_TYPE      ; 起動後に挿したカードも読めるように
        CMPNEI32 p1, r16, 0
        BR32 p1, .card
        CALL32 BIOS_SDINIT
        CMPEQI32 p1, r16, 0
        BR32 p1, .fail
.card:  ADDI32 r16, r0, 0               ; セクタ 0（MBR か、パーティションなしならブートセクタ）
        CALL32 sb_get
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
        CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
        LOAD16U_32 r16, r0, SECBUF + 510
        CMPNEI32 p1, r16, 0xAA55
        BR32 p1, .fail
        ADDI32 r16, r0, SECBUF + 11     ; 1 セクタ 512 バイトだけ対応
        CALL32 rd16
        CMPNEI32 p1, r16, 512
        BR32 p1, .fail
.bpb:   LOAD8U_32 r25, r0, SECBUF + 13  ; r25 = 1 クラスタのセクタ数
        CMPEQI32 p1, r25, 0
        BR32 p1, .fail
        STORE32_32 r25, r0, spc
        SHLI32 r16, r25, 9
        STORE32_32 r16, r0, clus_bytes
        ADDI32 r16, r0, SECBUF + 14     ; 予約セクタ数
        CALL32 rd16
        ADDR32 r16, r16, r24
        STORE32_32 r16, r0, fat_lba
        LOAD8U_32 r16, r0, SECBUF + 16  ; FAT の数
        STORE32_32 r16, r0, nfats
        ADDI32 r16, r0, SECBUF + 22     ; FAT の大きさ（FAT16）
        CALL32 rd16
        ADDR32 r26, r16, r0
        CMPNEI32 p1, r26, 0
        BR32 p1, .fsz
        ADDI32 r16, r0, SECBUF + 36     ; FAT の大きさ（FAT32）
        CALL32 rd32
        ADDR32 r26, r16, r0
.fsz:   STORE32_32 r26, r0, fat_sz
        LOAD32_32 r16, r0, nfats
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
        ADDI32 r17, r0, 2
        STORE32_32 r17, r0, free_hint
        STORE32_32 r0, r0, fsinfo_lba
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
        ADDI32 r16, r0, SECBUF + 48     ; FSInfo（空きクラスタ数と、次に探す場所）
        CALL32 rd16
        CMPEQI32 p1, r16, 0
        BR32 p1, .ok
        ADDR32 r16, r16, r24
        STORE32_32 r16, r0, fsinfo_lba
        CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .noinfo
        LOAD32_32 r16, r0, SECBUF + 484
        CMPNEI32 p1, r16, 0x61417272
        BR32 p1, .noinfo
        LOAD32_32 r16, r0, SECBUF + 488
        STORE32_32 r16, r0, fs_free
        LOAD32_32 r16, r0, SECBUF + 492
        STORE32_32 r16, r0, free_hint
        JMP32 .ok
.noinfo:
        STORE32_32 r0, r0, fsinfo_lba
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

; ---- セクタの置き場所（SECBUF）：1 つだけ覚えておき、書き換えたら替えるときに書き戻す ----

; sb_get(r16 = セクタ) → r16 = 0 なら SECBUF に入った
sb_get:
        LOAD32_32 r17, r0, sb_lba
        CMPNER32 p1, r16, r17
        BR32 p1, .load
        ADDI32 r16, r0, 0
        RET32
.load:  ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        CALL32 sb_flush
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r16, r0, -1
        STORE32_32 r16, r0, sb_lba
        ADDR32 r16, r24, r0
        ADDI32 r17, r0, SECBUF
        CALL32 BIOS_SDREAD
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        STORE32_32 r24, r0, sb_lba
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; sb_new(r16 = セクタ) → r16 = 0 なら成功。読まずに 0 で埋めて、そのセクタにする（新しく書くセクタ用）
sb_new:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        CALL32 sb_flush
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r16, r0, SECBUF
        ADDI32 r17, r0, SECBUF + 512
.z:     STORE32_32 r0, r16, 0
        ADDI32 r16, r16, 4
        CMPLTUR32 p1, r16, r17
        BR32 p1, .z
        STORE32_32 r24, r0, sb_lba
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, sb_dirty
        ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; sb_flush() → r16 = 0 なら成功。書き換えてあれば書き戻す
sb_flush:
        LOAD32_32 r16, r0, sb_dirty
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r0, r0, sb_dirty
        LOAD32_32 r16, r0, sb_lba
        ADDI32 r17, r0, SECBUF
        CALL32 BIOS_SDWRITE
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32
.ret:   ADDI32 r16, r0, 0
        RET32

; ---- FAT の置き場所（FATBUF）：同じく 1 セクタ。書き戻すときは FAT を全部（ふつう 2 つ）書く ----

; fc_load(r16 = FAT の中のセクタ番号) → r16 = 0 なら成功
fc_load:
        LOAD32_32 r17, r0, fc_sec
        CMPNER32 p1, r16, r17
        BR32 p1, .load
        ADDI32 r16, r0, 0
        RET32
.load:  ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        CALL32 fc_flush
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r16, r0, -1
        STORE32_32 r16, r0, fc_sec
        LOAD32_32 r16, r0, fat_lba
        ADDR32 r16, r16, r24
        ADDI32 r17, r0, FATBUF
        CALL32 BIOS_SDREAD
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        STORE32_32 r24, r0, fc_sec
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; fc_flush() → r16 = 0 なら成功
fc_flush:
        LOAD32_32 r16, r0, fc_dirty
        CMPEQI32 p1, r16, 0
        BR32 p1, .none
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r0, r0, fc_dirty
        LOAD32_32 r24, r0, fat_lba      ; 1 つ目の FAT のそのセクタ
        LOAD32_32 r16, r0, fc_sec
        ADDR32 r24, r24, r16
        LOAD32_32 r25, r0, nfats
.w:     ADDR32 r16, r24, r0
        ADDI32 r17, r0, FATBUF
        CALL32 BIOS_SDWRITE
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        LOAD32_32 r16, r0, fat_sz       ; 次の FAT の同じ場所
        ADDR32 r24, r24, r16
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, .w
        ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32
.none:  ADDI32 r16, r0, 0
        RET32

; fat_at(r16 = クラスタ) → r16 = FATBUF の中のその項目の番地（読めなければ 0）
fat_at:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p2, r17, 32
        SHLI32 r18, r16, 1
        SHLI32 r19, r16, 2
        SEL32 r24, r19, r18, p2         ; FAT の中のバイト位置
        SHRI32 r16, r24, 9
        CALL32 fc_load
        ADDI32 r17, r0, 0
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ANDI32 r17, r24, 511
        ADDI32 r17, r17, FATBUF
.ret:   ADDR32 r16, r17, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; fat_get(r16 = クラスタ) → r16 = FAT の値（FAT32 は下位 28bit）。読めなければ「終わり」の値
fat_get:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 fat_at
        CMPEQI32 p1, r16, 0
        BR32 p1, .err
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p2, r17, 32
        BR32 p2, .f32
        LOAD16U_32 r16, r16, 0
        JMP32 .ret
.f32:   LOAD32_32 r16, r16, 0
        ANDI32 r16, r16, 0x0FFFFFFF
        JMP32 .ret
.err:   ADDI32 r16, r0, 0x0FFFFFFF
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; fat_set(r16 = クラスタ, r17 = 値)
fat_set:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r17, r0
        CALL32 fat_at
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p2, r17, 32
        BR32 p2, .f32
        STORE16_32 r24, r16, 0
        JMP32 .dirty
.f32:   LOAD32_32 r17, r16, 0           ; 上位 4bit はそのまま残す
        ANDI32 r17, r17, 0xF0000000
        ANDI32 r24, r24, 0x0FFFFFFF
        ORR32 r17, r17, r24
        STORE32_32 r17, r16, 0
.dirty: ADDI32 r16, r0, 1
        STORE32_32 r16, r0, fc_dirty
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; eoc() → r16 = 「終わり」の印（FAT16 0xFFFF、FAT32 0x0FFFFFFF）。r17 を壊す
eoc:
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p2, r17, 32
        ADDI32 r16, r0, 0xFFFF
        ADDI32 r17, r0, 0x0FFFFFFF
        SEL32 r16, r17, r16, p2
        RET32

; next_clus(r16) → r16 = 次のクラスタ。終わりなら 0
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

; clus_lba(r16 = クラスタ) → r16 = 最初のセクタ。r17 を壊す
clus_lba:
        ADDI32 r16, r16, -2
        LOAD32_32 r17, r0, spc
        MULR32 r16, r16, r17
        LOAD32_32 r17, r0, data_lba
        ADDR32 r16, r16, r17
        RET32

; alloc() → r16 = 新しいクラスタ（「終わり」の印を付けてある）。空きがなければ 0
alloc:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        LOAD32_32 r26, r0, nclus
        ADDI32 r26, r26, 2              ; r26 = 最後のクラスタ + 1
        LOAD32_32 r24, r0, free_hint    ; ここから探す
        CMPLTUI32 p1, r24, 2
        BR32 p1, .wrap
        CMPGEUR32 p1, r24, r26
        BR32 p1, .wrap
        JMP32 .start
.wrap:  ADDI32 r24, r0, 2
.start: LOAD32_32 r25, r0, nclus        ; 全部見たら終わり
.l:     ADDR32 r16, r24, r0
        CALL32 fat_get
        CMPEQI32 p1, r16, 0
        BR32 p1, .found
        ADDI32 r24, r24, 1
        CMPLTUR32 p1, r24, r26
        BR32 p1, .n
        ADDI32 r24, r0, 2
.n:     ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, .l
        ADDI32 r16, r0, 0
        JMP32 .ret
.found: CALL32 eoc
        ADDR32 r17, r16, r0
        ADDR32 r16, r24, r0
        CALL32 fat_set
        ADDI32 r16, r24, 1
        STORE32_32 r16, r0, free_hint
        LOAD32_32 r16, r0, fs_free
        CMPEQI32 p1, r16, -1
        BR32 p1, .known
        ADDI32 r16, r16, -1
        STORE32_32 r16, r0, fs_free
.known: ADDR32 r16, r24, r0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; free_chain(r16 = 最初のクラスタ)：つながっているクラスタを全部空きにする
free_chain:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r16, r0
.l:     CMPLTUI32 p1, r24, 2
        BR32 p1, .ret
        ADDR32 r16, r24, r0
        CALL32 next_clus
        ADDR32 r25, r16, r0
        ADDR32 r16, r24, r0
        ADDI32 r17, r0, 0
        CALL32 fat_set
        LOAD32_32 r16, r0, fs_free
        CMPEQI32 p1, r16, -1
        BR32 p1, .next
        ADDI32 r16, r16, 1
        STORE32_32 r16, r0, fs_free
.next:  ADDR32 r24, r25, r0
        JMP32 .l
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; fs_sync()：書き換えたものを全部カードに書き戻す（FAT32 は FSInfo の空きクラスタ数も）
fs_sync:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 fc_flush
        LOAD32_32 r16, r0, fsinfo_lba
        CMPEQI32 p1, r16, 0
        BR32 p1, .sb
        LOAD32_32 r17, r0, fs_free
        CMPEQI32 p1, r17, -1
        BR32 p1, .sb
        CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .sb
        LOAD32_32 r16, r0, fs_free
        STORE32_32 r16, r0, SECBUF + 488
        LOAD32_32 r16, r0, free_hint
        STORE32_32 r16, r0, SECBUF + 492
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, sb_dirty
.sb:    CALL32 sb_flush
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; ---- ルートディレクトリ ----

; dir_open()：ルートディレクトリを最初から見る準備
dir_open:
        STORE32_32 r0, r0, d_end
        ADDI32 r16, r0, 16
        STORE32_32 r16, r0, d_idx       ; 次は新しいセクタへ進む
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

; dir_step() → r16 = 次の項目（SECBUF の中、そのまま）。e_lba・e_off にその場所。もうセクタがなければ 0
dir_step:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD32_32 r16, r0, d_idx
        CMPLTI32 p1, r16, 16
        BR32 p1, .have
        LOAD32_32 r16, r0, d_left       ; 次のセクタ
        CMPNEI32 p1, r16, 0
        BR32 p1, .adv
        LOAD32_32 r16, r0, d_clus       ; 次のクラスタ（FAT16 のルートなら終わり）
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        CALL32 next_clus
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        STORE32_32 r16, r0, d_clus
        CALL32 clus_lba
        STORE32_32 r16, r0, d_lba
        LOAD32_32 r16, r0, spc
        STORE32_32 r16, r0, d_left
.adv:   LOAD32_32 r16, r0, d_lba
        STORE32_32 r16, r0, d_cur
        ADDI32 r16, r16, 1
        STORE32_32 r16, r0, d_lba
        LOAD32_32 r16, r0, d_left
        ADDI32 r16, r16, -1
        STORE32_32 r16, r0, d_left
        STORE32_32 r0, r0, d_idx
.have:  LOAD32_32 r16, r0, d_cur
        CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .end
        LOAD32_32 r16, r0, d_cur
        STORE32_32 r16, r0, e_lba
        LOAD32_32 r16, r0, d_idx
        ADDI32 r17, r16, 1
        STORE32_32 r17, r0, d_idx
        SHLI32 r16, r16, 5
        STORE32_32 r16, r0, e_off
        ADDI32 r16, r16, SECBUF
        JMP32 .ret
.end:   ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; dir_next() → r16 = 次の項目を dent に写したもの。終わりなら 0。消した項目と長い名前の項目は飛ばし、
; 飛ばした長い名前の項目の場所は lfn に覚えておく（消すときに一緒に消すため）
dir_next:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r0, r0, lfn_n
.again: LOAD32_32 r16, r0, d_end
        CMPNEI32 p1, r16, 0
        BR32 p1, .end
        CALL32 dir_step
        CMPEQI32 p1, r16, 0
        BR32 p1, .end
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0             ; ここで終わり
        BR32 p1, .end
        CMPEQI32 p1, r17, 0xE5          ; 消したファイル
        BR32 p1, .del
        LOAD8U_32 r17, r16, 11
        CMPEQI32 p1, r17, 0x0F          ; 長いファイル名の項目
        BR32 p1, .lfn
        ADDI32 r17, r0, 0               ; dent に写す
.cp:    ADDR32 r18, r16, r17
        LOAD32_32 r18, r18, 0
        STORE32_32 r18, r17, dent
        ADDI32 r17, r17, 4
        CMPLTI32 p1, r17, 32
        BR32 p1, .cp
        ADDI32 r16, r0, dent
        JMP32 .ret
.del:   STORE32_32 r0, r0, lfn_n
        JMP32 .again
.lfn:   LOAD32_32 r17, r0, lfn_n
        CMPGEI32 p1, r17, 20
        BR32 p1, .again
        SHLI32 r18, r17, 3
        LOAD32_32 r19, r0, e_lba
        STORE32_32 r19, r18, lfn
        LOAD32_32 r19, r0, e_off
        STORE32_32 r19, r18, lfn + 4
        ADDI32 r17, r17, 1
        STORE32_32 r17, r0, lfn_n
        JMP32 .again
.end:   ADDI32 r16, r0, 1
        STORE32_32 r16, r0, d_end
        ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; fs_find() → r16 = 1 なら見つけた。name83 の名前を探し、ent に写して、場所を f_lba・f_off に
fs_find:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 dir_open
.l:     CALL32 dir_next
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        LOAD8U_32 r17, r0, dent + 11    ; ボリュームラベルは除く
        ANDI32 r17, r17, 0x08
        CMPNEI32 p1, r17, 0
        BR32 p1, .l
        ADDI32 r17, r0, 0               ; 11 文字を比べる
.cmp:   LOAD8U_32 r18, r17, dent
        LOAD8U_32 r19, r17, name83
        CMPNER32 p1, r18, r19
        BR32 p1, .l
        ADDI32 r17, r17, 1
        CMPLTI32 p1, r17, 11
        BR32 p1, .cmp
        ADDI32 r17, r0, 0
.cp:    LOAD32_32 r18, r17, dent
        STORE32_32 r18, r17, ent
        ADDI32 r17, r17, 4
        CMPLTI32 p1, r17, 32
        BR32 p1, .cp
        LOAD32_32 r16, r0, e_lba
        STORE32_32 r16, r0, f_lba
        LOAD32_32 r16, r0, e_off
        STORE32_32 r16, r0, f_off
        ADDI32 r16, r0, 1
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; dir_slot() → r16 = 1 なら空いている項目を見つけた（e_lba・e_off）。FAT32 で足りなければクラスタを足す
dir_slot:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        CALL32 dir_open
.l:     CALL32 dir_step
        CMPEQI32 p1, r16, 0
        BR32 p1, .full
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .ok
        CMPEQI32 p1, r17, 0xE5
        BR32 p1, .ok
        JMP32 .l
.full:  LOAD32_32 r24, r0, d_clus       ; FAT16 のルートはいっぱい
        CMPEQI32 p1, r24, 0
        BR32 p1, .fail
        CALL32 alloc                    ; FAT32：ルートのつながりの最後にクラスタを足して 0 で埋める
        CMPEQI32 p1, r16, 0
        BR32 p1, .fail
        ADDR32 r25, r16, r0
        ADDR32 r17, r25, r0
        ADDR32 r16, r24, r0
        CALL32 fat_set
        ADDR32 r16, r25, r0
        CALL32 clus_lba
        ADDR32 r24, r16, r0
        LOAD32_32 r25, r0, spc
.zs:    ADDR32 r16, r24, r0
        CALL32 sb_new
        ADDI32 r24, r24, 1
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, .zs
        LOAD32_32 r16, r0, spc          ; 最初のセクタの先頭
        SUBR32 r16, r24, r16
        STORE32_32 r16, r0, e_lba
        STORE32_32 r0, r0, e_off
        CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .fail
.ok:    ADDI32 r16, r0, 1
        JMP32 .ret
.fail:  ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; kill_lfn()：dir_next が覚えた長い名前の項目を「消した」にする
kill_lfn:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r24, r0, lfn_n
.l:     CMPEQI32 p1, r24, 0
        BR32 p1, .ret
        ADDI32 r24, r24, -1
        SHLI32 r16, r24, 3
        LOAD32_32 r16, r16, lfn
        CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .l
        SHLI32 r16, r24, 3
        LOAD32_32 r16, r16, lfn + 4
        ADDI32 r17, r0, 0xE5
        STORE8_32 r17, r16, SECBUF
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, sb_dirty
        JMP32 .l
.ret:   STORE32_32 r0, r0, lfn_n
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; ent_ptr(r16 = セクタ, r17 = 位置) → r16 = SECBUF の中のその項目（読めなければ 0）
ent_ptr:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r17, r0
        CALL32 sb_get
        ADDI32 r17, r0, 0
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r17, r24, SECBUF
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, sb_dirty    ; 書き換える前提
.ret:   ADDR32 r16, r17, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; ---- ファイルのハンドル ----

; h_ptr(r16 = ハンドル) → r16 = その中身の番地
h_ptr:
        SHLI32 r16, r16, 5
        ADDI32 r16, r16, handles
        RET32

; h_check(r16 = ハンドル) → r16 = 中身の番地。正しくなければ 0
h_check:
        CMPGEUI32 p1, r16, NFILES
        BR32 p1, .bad
        SHLI32 r16, r16, 5
        ADDI32 r16, r16, handles
        LOAD32_32 r17, r16, H_MODE
        CMPNEI32 p1, r17, 0
        BR32 p1, .ok
.bad:   ADDI32 r16, r0, 0
.ok:    RET32

; f_open(r16 = 名前, r17 = モード) → r16 = ハンドル（負ならエラー）。SYSCALL 16
f_open:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r17, r0
        CALL32 to83
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -6
        BR32 p1, .ret
        ADDR32 r16, r24, r0
        CALL32 f_open83
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; f_open83(r16 = モード) → r16 = ハンドル。名前は name83 に入っている
f_open83:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        ADDR32 r25, r16, r0             ; r25 = モード
        LOAD32_32 r16, r0, fs_ok
        CMPNEI32 p1, r16, 0
        BR32 p1, .mounted
        CALL32 fs_mount
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -7
        BR32 p1, .ret
.mounted:
        ADDI32 r24, r0, 0               ; 空いているハンドルを探す
.h:     ADDR32 r16, r24, r0
        CALL32 h_ptr
        LOAD32_32 r17, r16, H_MODE
        CMPEQI32 p1, r17, 0
        BR32 p1, .free
        ADDI32 r24, r24, 1
        CMPLTI32 p1, r24, NFILES
        BR32 p1, .h
        ADDI32 r16, r0, -3
        JMP32 .ret
.free:  ADDR32 r26, r16, r0             ; r26 = ハンドルの中身
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        BR32 p1, .new
        LOAD8U_32 r17, r0, ent + 11     ; ディレクトリ・ラベルは開けない
        ANDI32 r18, r17, 0x18
        CMPNEI32 p1, r18, 0
        ADDI32 r16, r0, -5
        BR32 p1, .ret
        CMPEQI32 p1, r25, 0
        BR32 p1, .exist
        ANDI32 r18, r17, 0x01           ; 読み出し専用には書けない
        CMPNEI32 p1, r18, 0
        BR32 p1, .ret
.exist: LOAD16U_32 r27, r0, ent + 26    ; 最初のクラスタ
        LOAD16U_32 r16, r0, ent + 20
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p1, r17, 32
        SHLI32 r16, r16, 16
        SEL32 r16, r16, r0, p1
        ORR32 r27, r27, r16
        STORE32_32 r27, r26, H_FIRST
        LOAD32_32 r16, r0, ent + 28
        STORE32_32 r16, r26, H_SIZE
        LOAD32_32 r16, r0, f_lba
        STORE32_32 r16, r26, H_DLBA
        LOAD32_32 r16, r0, f_off
        STORE32_32 r16, r26, H_DOFF
        CMPNEI32 p1, r25, 1
        BR32 p1, .set
        ADDR32 r16, r27, r0             ; 新しく書く：中身を捨てる
        CALL32 free_chain
        STORE32_32 r0, r26, H_FIRST
        STORE32_32 r0, r26, H_SIZE
        JMP32 .set
.new:   CMPEQI32 p1, r25, 0             ; 読むのにファイルがない
        ADDI32 r16, r0, -2
        BR32 p1, .ret
        CALL32 dir_slot
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -4
        BR32 p1, .ret
        LOAD32_32 r16, r0, e_lba
        STORE32_32 r16, r26, H_DLBA
        LOAD32_32 r17, r0, e_off
        STORE32_32 r17, r26, H_DOFF
        CALL32 ent_ptr                  ; 項目を作る
        CMPEQI32 p1, r16, 0
        ADDI32 r17, r0, -4
        BR32 p1, .err
        ADDI32 r17, r0, 0
.cp:    LOAD32_32 r18, r17, name83      ; 名前（11 バイト）と属性、残りは 0
        STORE32_32 r18, r16, 0
        ADDI32 r16, r16, 4
        ADDI32 r17, r17, 4
        CMPLTI32 p1, r17, 8
        BR32 p1, .cp
        LOAD32_32 r18, r0, name83 + 8
        ANDI32 r18, r18, 0xFFFFFF
        ORI32 r18, r18, 0x20000000      ; 属性 0x20（アーカイブ）
        STORE32_32 r18, r16, 0
        STORE32_32 r0, r16, 4
        STORE32_32 r0, r16, 8
        STORE32_32 r0, r16, 12
        STORE32_32 r0, r16, 16
        STORE32_32 r0, r16, 20
        ADDI32 r18, r0, FAT_DATE        ; 作った日・書いた日（時刻は 0:00）
        STORE16_32 r18, r16, 8
        STORE16_32 r18, r16, 10
        STORE16_32 r18, r16, 16
        STORE32_32 r0, r26, H_FIRST
        STORE32_32 r0, r26, H_SIZE
        ADDI32 r25, r0, 1
.set:   ADDI32 r16, r0, 1               ; モード：読む 1、書く 2
        CMPNEI32 p1, r25, 0
        ADDI32 r17, r0, 2
        SEL32 r16, r17, r16, p1
        STORE32_32 r16, r26, H_MODE
        STORE32_32 r0, r26, H_POS
        STORE32_32 r0, r26, H_CLUS
        STORE32_32 r0, r26, H_CIDX
        CMPNEI32 p1, r25, 2             ; 後ろに足す：最後のクラスタまで進めておく
        BR32 p1, .done
        LOAD32_32 r27, r26, H_SIZE
        STORE32_32 r27, r26, H_POS
        CMPEQI32 p1, r27, 0
        BR32 p1, .done
        ADDI32 r27, r27, -1
        LOAD32_32 r16, r0, clus_bytes
        DIVUR32 r27, r27, r16           ; 最後のクラスタは何番目か
        STORE32_32 r27, r26, H_CIDX
        LOAD32_32 r16, r26, H_FIRST
.walk:  CMPEQI32 p1, r27, 0
        BR32 p1, .last
        CALL32 next_clus
        ADDI32 r27, r27, -1
        JMP32 .walk
.last:  STORE32_32 r16, r26, H_CLUS
.done:  ADDR32 r16, r24, r0
        JMP32 .ret
.err:   STORE32_32 r0, r26, H_MODE
        ADDR32 r16, r17, r0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

; seek_clus(r16 = ハンドルの中身) → r16 = 位置 H_POS のあるクラスタ（0 ならない）。H_CLUS・H_CIDX を進める
seek_clus:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r16, r0
        LOAD32_32 r25, r24, H_POS       ; 何番目のクラスタか
        LOAD32_32 r16, r0, clus_bytes
        DIVUR32 r25, r25, r16
        LOAD32_32 r16, r24, H_CLUS
        CMPEQI32 p1, r16, 0
        BR32 p1, .first
        LOAD32_32 r17, r24, H_CIDX
        CMPLTUR32 p1, r25, r17
        BR32 p1, .first
        JMP32 .walk
.first: LOAD32_32 r16, r24, H_FIRST
        STORE32_32 r16, r24, H_CLUS
        STORE32_32 r0, r24, H_CIDX
.walk:  LOAD32_32 r17, r24, H_CIDX
        CMPGEUR32 p1, r17, r25
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_CLUS
        CALL32 next_clus
        STORE32_32 r16, r24, H_CLUS
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        LOAD32_32 r17, r24, H_CIDX
        ADDI32 r17, r17, 1
        STORE32_32 r17, r24, H_CIDX
        JMP32 .walk
.ret:   LOAD32_32 r16, r24, H_CLUS
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; pos_lba(r16 = ハンドルの中身, r17 = クラスタ) → r16 = 位置 H_POS のあるセクタ
pos_lba:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        LOAD32_32 r24, r16, H_POS
        LOAD32_32 r18, r0, clus_bytes
        REMUR32 r24, r24, r18
        SHRI32 r24, r24, 9
        ADDR32 r16, r17, r0
        CALL32 clus_lba
        ADDR32 r16, r16, r24
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; f_read(r16 = ハンドル, r17 = 置き場所, r18 = 長さ) → r16 = 読んだ長さ（終わりなら 0、負ならエラー）。SYSCALL 18
f_read:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        ADDR32 r25, r17, r0             ; r25 = 置き場所
        ADDR32 r26, r18, r0             ; r26 = 残り
        ADDI32 r27, r0, 0               ; r27 = 読んだ長さ
        CALL32 h_check
        ADDR32 r24, r16, r0
        CMPEQI32 p1, r24, 0
        ADDI32 r27, r0, -1
        BR32 p1, .ret
        ADDI32 r27, r0, 0
        LOAD32_32 r16, r24, H_SIZE      ; ファイルの残りより多くは読まない
        LOAD32_32 r17, r24, H_POS
        SUBR32 r16, r16, r17
        CMPLTUR32 p1, r16, r26
        SEL32 r26, r16, r26, p1
.l:     CMPEQI32 p1, r26, 0
        BR32 p1, .ret
        ADDR32 r16, r24, r0
        CALL32 seek_clus
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        ADDR32 r17, r16, r0
        ADDR32 r16, r24, r0
        CALL32 pos_lba
        ; セクタの頭から 512 バイト以上読むなら、セクタの置き場を通さずに直接読む
        ; （置き場にそのセクタがあれば、書きかけかもしれないので置き場から）
        LOAD32_32 r17, r24, H_POS
        ANDI32 r17, r17, 511
        CMPNEI32 p1, r17, 0
        BR32 p1, .buf
        CMPLTUI32 p1, r26, 512
        BR32 p1, .buf
        LOAD32_32 r17, r0, sb_lba
        CMPEQR32 p1, r16, r17
        BR32 p1, .buf
        ADDR32 r17, r25, r0
        CALL32 BIOS_SDREAD
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r17, r0, 512
        ADDI32 r25, r25, 512
        JMP32 .adv
.buf:   CALL32 sb_get
        CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_POS       ; このセクタから写す長さ（1 以上）
        ANDI32 r16, r16, 511
        ADDI32 r17, r0, 512
        SUBR32 r17, r17, r16
        CMPLTUR32 p1, r26, r17
        SEL32 r17, r26, r17, p1
        ADDI32 r16, r16, SECBUF
        ADDR32 r18, r16, r17
        ORR32 r19, r16, r25             ; 元・先・長さが 4 の倍数なら 4 バイトずつ
        ORR32 r19, r19, r17
        ANDI32 r19, r19, 3
        CMPNEI32 p1, r19, 0
        BR32 p1, .cp
.cw:    LOAD32_32 r19, r16, 0
        STORE32_32 r19, r25, 0
        ADDI32 r16, r16, 4
        ADDI32 r25, r25, 4
        CMPLTUR32 p1, r16, r18
        BR32 p1, .cw
        JMP32 .adv
.cp:    LOAD8U_32 r19, r16, 0
        STORE8_32 r19, r25, 0
        ADDI32 r16, r16, 1
        ADDI32 r25, r25, 1
        CMPLTUR32 p1, r16, r18
        BR32 p1, .cp
.adv:   LOAD32_32 r16, r24, H_POS
        ADDR32 r16, r16, r17
        STORE32_32 r16, r24, H_POS
        ADDR32 r27, r27, r17
        SUBR32 r26, r26, r17
        JMP32 .l
.ret:   ADDR32 r16, r27, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

; f_seek(r16 = ハンドル, r17 = 位置, r18 = 基準) → r16 = 新しい位置（負ならエラー）。SYSCALL 22
;   基準 0 = 先頭から、1 = 今の位置から、2 = 終わりから。0 ≦ 新しい位置 ≦ 大きさ。
;   読むファイルはどこへでも（seek_clus が位置からクラスタを求め直す）。書くファイルは後ろに足すだけなので、終わりだけ
f_seek:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDR32 r24, r17, r0             ; 位置
        ADDR32 r25, r18, r0             ; 基準
        CALL32 h_check
        CMPEQI32 p1, r16, 0
        BR32 p1, .bad
        CMPEQI32 p1, r25, 1
        BR32 p1, .cur
        CMPEQI32 p1, r25, 2
        BR32 p1, .end
        CMPEQI32 p1, r25, 0
        BR32 p1, .set
        JMP32 .inval
.cur:   LOAD32_32 r17, r16, H_POS
        ADDR32 r24, r24, r17
        JMP32 .set
.end:   LOAD32_32 r17, r16, H_SIZE
        ADDR32 r24, r24, r17
.set:   LOAD32_32 r17, r16, H_SIZE      ; 大きさを超える（負も符号なしで大きい）のはだめ
        CMPLTUR32 p1, r17, r24
        BR32 p1, .inval
        LOAD32_32 r17, r16, H_MODE
        CMPEQI32 p1, r17, 1             ; 読むファイル
        BR32 p1, .ok
        LOAD32_32 r17, r16, H_POS       ; 書くファイルは今の位置（終わり）だけ
        CMPNER32 p1, r24, r17
        BR32 p1, .inval
.ok:    STORE32_32 r24, r16, H_POS
        ADDR32 r16, r24, r0
        JMP32 .ret
.inval: ADDI32 r16, r0, -5
        JMP32 .ret
.bad:   ADDI32 r16, r0, -1
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; f_write(r16 = ハンドル, r17 = データ, r18 = 長さ) → r16 = 書いた長さ（負ならエラー）。後ろに足すだけ。SYSCALL 19
f_write:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        ADDR32 r25, r17, r0
        ADDR32 r26, r18, r0
        ADDI32 r27, r0, -1
        CALL32 h_check
        ADDR32 r24, r16, r0
        CMPEQI32 p1, r24, 0
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_MODE
        CMPNEI32 p1, r16, 2
        BR32 p1, .ret
        ADDI32 r27, r0, 0
.l:     CMPEQI32 p1, r26, 0
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_POS       ; クラスタの区切りなら新しいクラスタをつなぐ
        LOAD32_32 r17, r0, clus_bytes
        REMUR32 r16, r16, r17
        CMPNEI32 p1, r16, 0
        BR32 p1, .have
        CALL32 alloc
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret                   ; 空きがない
        ADDR32 r17, r16, r0
        LOAD32_32 r16, r24, H_FIRST
        CMPNEI32 p1, r16, 0
        BR32 p1, .link
        STORE32_32 r17, r24, H_FIRST
        JMP32 .cur
.link:  STORE32_32 r17, sp, 20          ; 前のクラスタの次 ← 新しいクラスタ
        LOAD32_32 r16, r24, H_CLUS
        CALL32 fat_set
        LOAD32_32 r17, sp, 20
.cur:   STORE32_32 r17, r24, H_CLUS
        LOAD32_32 r16, r24, H_POS
        LOAD32_32 r18, r0, clus_bytes
        DIVUR32 r16, r16, r18
        STORE32_32 r16, r24, H_CIDX
.have:  LOAD32_32 r17, r24, H_CLUS
        ADDR32 r16, r24, r0
        CALL32 pos_lba
        LOAD32_32 r17, r24, H_POS       ; セクタの頭からなら読まずに新しく
        ANDI32 r17, r17, 511
        CMPEQI32 p1, r17, 0
        BR32 p1, .fresh
        CALL32 sb_get
        JMP32 .chk
.fresh: CALL32 sb_new
.chk:   CMPNEI32 p1, r16, 0
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_POS
        ANDI32 r16, r16, 511
        ADDI32 r17, r0, 512
        SUBR32 r17, r17, r16
        CMPLTUR32 p1, r26, r17
        SEL32 r17, r26, r17, p1
        ADDI32 r16, r16, SECBUF
        ADDR32 r18, r16, r17
.cp:    CMPGEUR32 p1, r16, r18
        BR32 p1, .adv
        LOAD8U_32 r19, r25, 0
        STORE8_32 r19, r16, 0
        ADDI32 r16, r16, 1
        ADDI32 r25, r25, 1
        JMP32 .cp
.adv:   ADDI32 r16, r0, 1
        STORE32_32 r16, r0, sb_dirty
        LOAD32_32 r16, r24, H_POS
        ADDR32 r16, r16, r17
        STORE32_32 r16, r24, H_POS
        STORE32_32 r16, r24, H_SIZE
        ADDR32 r27, r27, r17
        SUBR32 r26, r26, r17
        JMP32 .l
.ret:   ADDR32 r16, r27, r0
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

; f_close(r16 = ハンドル) → r16 = 0 なら成功。書いたファイルはディレクトリの項目（最初のクラスタ・大きさ）を直す。SYSCALL 17
f_close:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        CALL32 h_check
        ADDR32 r24, r16, r0
        CMPEQI32 p1, r24, 0
        ADDI32 r16, r0, -1
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_MODE
        STORE32_32 r0, r24, H_MODE
        CMPNEI32 p1, r16, 2
        ADDI32 r16, r0, 0
        BR32 p1, .ret
        LOAD32_32 r16, r24, H_DLBA
        LOAD32_32 r17, r24, H_DOFF
        CALL32 ent_ptr
        CMPEQI32 p1, r16, 0
        BR32 p1, .err
        LOAD32_32 r17, r24, H_FIRST
        STORE16_32 r17, r16, 26
        SHRI32 r17, r17, 16
        STORE16_32 r17, r16, 20
        LOAD32_32 r17, r24, H_SIZE
        STORE32_32 r17, r16, 28
        ADDI32 r17, r0, FAT_DATE        ; 書いた日
        STORE16_32 r17, r16, 24
        STORE16_32 r0, r16, 22
        CALL32 fs_sync
        JMP32 .ret
.err:   ADDI32 r16, r0, -7
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; close_all()：開いているファイルを全部閉じる
close_all:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDI32 r24, r0, 0
.l:     ADDR32 r16, r24, r0
        CALL32 f_close
        ADDI32 r24, r24, 1
        CMPLTI32 p1, r24, NFILES
        BR32 p1, .l
        LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; f_delete(r16 = 名前) → r16 = 0 なら成功。SYSCALL 20
f_delete:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        CALL32 to83
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -6
        BR32 p1, .ret
        CALL32 mounted
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -7
        BR32 p1, .ret
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -2
        BR32 p1, .ret
        LOAD8U_32 r17, r0, ent + 11     ; 読み出し専用・ディレクトリ・ラベルは消さない
        ANDI32 r17, r17, 0x19
        CMPNEI32 p1, r17, 0
        ADDI32 r16, r0, -5
        BR32 p1, .ret
        CALL32 kill_lfn                 ; 長い名前の項目、本体の項目、中身の順に消す
        LOAD32_32 r16, r0, f_lba
        LOAD32_32 r17, r0, f_off
        CALL32 ent_ptr
        CMPEQI32 p1, r16, 0
        BR32 p1, .nr
        ADDI32 r17, r0, 0xE5
        STORE8_32 r17, r16, 0
        LOAD16U_32 r24, r0, ent + 26
        LOAD16U_32 r16, r0, ent + 20
        LOAD32_32 r17, r0, fs_type
        CMPEQI32 p1, r17, 32
        SHLI32 r16, r16, 16
        SEL32 r16, r16, r0, p1
        ORR32 r16, r24, r16
        CALL32 free_chain
        CALL32 fs_sync
        ADDI32 r16, r0, 0
        JMP32 .ret
.nr:    ADDI32 r16, r0, -7              ; カードが読めない
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; f_rename(r16 = 前の名前, r17 = 新しい名前) → r16 = 0 なら成功。SYSCALL 21
f_rename:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        ADDR32 r16, r17, r0             ; 新しい名前を newname へ
        CALL32 to83
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -6
        BR32 p1, .ret
        LOAD32_32 r16, r0, name83
        STORE32_32 r16, r0, newname
        LOAD32_32 r16, r0, name83 + 4
        STORE32_32 r16, r0, newname + 4
        LOAD32_32 r16, r0, name83 + 8
        STORE32_32 r16, r0, newname + 8
        CALL32 mounted
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -7
        BR32 p1, .ret
        CALL32 fs_find                  ; 同じ名前がもうある
        CMPNEI32 p1, r16, 0
        ADDI32 r16, r0, -5
        BR32 p1, .ret
        ADDR32 r16, r24, r0
        CALL32 to83
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -6
        BR32 p1, .ret
        CALL32 fs_find
        CMPEQI32 p1, r16, 0
        ADDI32 r16, r0, -2
        BR32 p1, .ret
        LOAD8U_32 r17, r0, ent + 11
        ANDI32 r17, r17, 0x08
        CMPNEI32 p1, r17, 0
        ADDI32 r16, r0, -5
        BR32 p1, .ret
        CALL32 kill_lfn                 ; 長い名前は古い名前のものなので消す
        LOAD32_32 r16, r0, f_lba
        LOAD32_32 r17, r0, f_off
        CALL32 ent_ptr
        CMPEQI32 p1, r16, 0
        BR32 p1, .nr
        ADDI32 r17, r0, 0               ; 11 文字を書き換える
.cp:    LOAD8U_32 r18, r17, newname
        ADDR32 r19, r16, r17
        STORE8_32 r18, r19, 0
        ADDI32 r17, r17, 1
        CMPLTI32 p1, r17, 11
        BR32 p1, .cp
        CALL32 fs_sync
        ADDI32 r16, r0, 0
        JMP32 .ret
.nr:    ADDI32 r16, r0, -7              ; カードが読めない
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; mounted() → r16 = 1 ならカードが読める（メッセージは出さない）
mounted:
        LOAD32_32 r16, r0, fs_ok
        CMPNEI32 p1, r16, 0
        BR32 p1, .ok
        JMP32 fs_mount
.ok:    RET32

; ==================================================================
; 組み込みのコマンド（r16 = 引数）
; ==================================================================
commands:
        .word c_cls, cmd_cls
        .word c_color, cmd_color
        .word c_copy, cmd_copy
        .word c_del, cmd_del
        .word c_erase, cmd_del
        .word c_dir, cmd_dir
        .word c_echo, cmd_echo
        .word c_help, cmd_help
        .word c_led, cmd_led
        .word c_mem, cmd_mem
        .word c_reboot, cmd_reboot
        .word c_ren, cmd_ren
        .word c_rename, cmd_ren
        .word c_shutdown, cmd_shutdown
        .word c_time, cmd_time
        .word c_type, cmd_type
        .word c_ver, cmd_ver
        .word c_vol, cmd_vol
        .word 0, 0

cmd_help:
        ADDI32 r16, r0, s_help
        JMP32 puts
cmd_ver:
        ADDI32 r16, r0, s_ver
        JMP32 puts
cmd_mem:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        ADDI32 r16, r0, s_mem
        CALL32 puts
        LOAD32_32 r16, r0, SDRAM_KB     ; BIOS が調べた SDRAM の大きさ（0 ならなし）
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        SHLI32 r16, r16, 10
        ADDI32 r17, r0, 8
        CALL32 putdec_w
        ADDI32 r16, r0, s_mem_sdram
        CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32
cmd_reboot:
        CALL32 close_all
        JMP32 BIOS_REBOOT
cmd_cls:
        ADDI32 r16, r0, 1
        STORE32_32 r16, r0, quiet
        JMP32 BIOS_CLS

cmd_echo:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 puts
        ADDI32 r16, r0, 10
        CALL32 putc
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

cmd_shutdown:
        CALL32 close_all
        ADDI32 r16, r0, 0x0E            ; 黒地に黄色
        CALL32 BIOS_SETATTR
        CALL32 BIOS_CLS
        ADDI32 r16, r0, s_safe
        CALL32 BIOS_PUTS
        HLT

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
        CALL32 puts
        ADDI32 r16, r0, vol_label
        CALL32 puts
        ADDI32 r16, r0, s_vol2
        CALL32 puts
        LOAD32_32 r16, r0, fs_serial    ; XXXX-XXXX
        SHRI32 r16, r16, 16
        ADDI32 r17, r0, 4
        CALL32 puthexn
        ADDI32 r16, r0, '-'
        CALL32 putc
        LOAD32_32 r16, r0, fs_serial
        ADDI32 r17, r0, 4
        CALL32 puthexn
        ADDI32 r16, r0, 10
        CALL32 putc
        LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
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
        CALL32 puts
        ADDI32 r25, r0, 0               ; ファイルの数
        ADDI32 r26, r0, 0               ; 合計の大きさ
        CALL32 dir_open                 ; （dir_next は項目を dent に写すので、一覧を出す間にリダイレクト先へ書いてもよい）
.l:     CALL32 dir_next
        CMPEQI32 p1, r16, 0
        BR32 p1, .sum
        ADDI32 r24, r0, dent
        LOAD8U_32 r17, r24, 11
        ANDI32 r17, r17, 0x0A           ; ボリュームラベルと隠しファイルは出さない
        CMPNEI32 p1, r17, 0
        BR32 p1, .l
        ADDR32 r16, r24, r0             ; 名前 8 文字、空白、拡張子 3 文字
        ADDI32 r17, r0, 8
        CALL32 putn
        ADDI32 r16, r0, ' '
        CALL32 putc
        ADDI32 r16, r24, 8
        ADDI32 r17, r0, 3
        CALL32 putn
        LOAD8U_32 r17, r24, 11
        ANDI32 r17, r17, 0x10
        CMPEQI32 p1, r17, 0
        BR32 p1, .size
        ADDI32 r16, r0, s_dirtag        ; ディレクトリ
        CALL32 puts
        JMP32 .date
.size:  LOAD32_32 r16, r24, 28
        ADDR32 r26, r26, r16
        ADDI32 r17, r0, 10
        CALL32 putdec_w
        ADDI32 r16, r0, ' '
        CALL32 putc
.date:  LOAD16U_32 r16, r24, 24         ; 日付：月-日-年
        SHRI32 r16, r16, 5
        ANDI32 r16, r16, 15
        CALL32 put2
        ADDI32 r16, r0, '-'
        CALL32 putc
        LOAD16U_32 r16, r24, 24
        ANDI32 r16, r16, 31
        CALL32 put2
        ADDI32 r16, r0, '-'
        CALL32 putc
        LOAD16U_32 r16, r24, 24
        SHRI32 r16, r16, 9
        ADDI32 r16, r16, 1980
        REMUI32 r16, r16, 100
        CALL32 put2
        ADDI32 r16, r0, s_sp2
        CALL32 puts
        LOAD16U_32 r16, r24, 22         ; 時刻：12 時間で a / p
        SHRI32 r16, r16, 11
        REMUI32 r17, r16, 12
        CMPEQI32 p1, r17, 0
        ADDI32 r18, r0, 12
        SEL32 r16, r18, r17, p1
        ADDI32 r17, r0, 2
        CALL32 putdec_w
        ADDI32 r16, r0, ':'
        CALL32 putc
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
        CALL32 putc
        ADDI32 r16, r0, 10
        CALL32 putc
        ADDI32 r25, r25, 1
        JMP32 .l
.sum:   ADDR32 r16, r25, r0             ; "    n file(s)     合計 bytes"
        ADDI32 r17, r0, 9
        CALL32 putdec_w
        ADDI32 r16, r0, s_files
        CALL32 puts
        ADDR32 r16, r26, r0
        ADDI32 r17, r0, 14
        CALL32 putdec_w
        ADDI32 r16, r0, s_bytes
        CALL32 puts
        CALL32 count_free               ; 空き
        CMPEQI32 p1, r16, -1
        BR32 p1, .ret
        LOAD32_32 r17, r0, clus_bytes
        MULHUR32 r18, r16, r17          ; 4GB を超えるなら KB で出す
        CMPNEI32 p1, r18, 0
        BR32 p1, .kb
        MULR32 r16, r16, r17
        ADDI32 r17, r0, 28
        CALL32 putdec_w
        ADDI32 r16, r0, s_free
        CALL32 puts
        JMP32 .ret
.kb:    SHRI32 r17, r17, 10
        MULR32 r16, r16, r17
        ADDI32 r17, r0, 28
        CALL32 putdec_w
        ADDI32 r16, r0, s_freekb
        CALL32 puts
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

; ferr(r16 = エラー番号)：エラーの説明を出す
ferr:
        ADDI32 r17, r0, s_notfound
        CMPEQI32 p1, r16, -3
        ADDI32 r18, r0, s_toomany
        SEL32 r17, r18, r17, p1
        CMPEQI32 p1, r16, -4
        ADDI32 r18, r0, s_diskfull
        SEL32 r17, r18, r17, p1
        CMPEQI32 p1, r16, -5
        ADDI32 r18, r0, s_denied
        SEL32 r17, r18, r17, p1
        CMPEQI32 p1, r16, -7
        ADDI32 r18, r0, s_notready
        SEL32 r17, r18, r17, p1
        ADDR32 r16, r17, r0
        JMP32 puts

; TYPE ファイル名：中身を出す（Ctrl-Z で終わり）
cmd_type:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .missing
        ADDI32 r17, r0, 0
        CALL32 f_open
        CMPLTI32 p1, r16, 0
        BR32 p1, .err
        ADDR32 r24, r16, r0
        ADDI32 r26, r0, 10              ; 最後に出した文字
.rd:    ADDR32 r16, r24, r0
        ADDI32 r17, r0, COPYBUF
        ADDI32 r18, r0, 512
        CALL32 f_read
        CMPLTI32 p1, r16, 1
        BR32 p1, .eof
        ADDI32 r25, r0, COPYBUF
        ADDI32 r16, r16, COPYBUF
        STORE32_32 r16, r0, tmp
.c:     LOAD32_32 r16, r0, tmp
        CMPGEUR32 p1, r25, r16
        BR32 p1, .rd
        LOAD8U_32 r16, r25, 0
        ADDI32 r25, r25, 1
        CMPEQI32 p1, r16, 0x1A          ; Ctrl-Z
        BR32 p1, .eof
        CMPEQI32 p1, r16, 13            ; \r は捨てる（\n で改行）
        BR32 p1, .c
        ADDR32 r26, r16, r0
        CMPEQI32 p1, r16, 10
        BR32 p1, .nl
        CALL32 putg
        JMP32 .c
.nl:    CALL32 putc
        JMP32 .c
.eof:   ADDR32 r16, r24, r0
        CALL32 f_close
        CMPEQI32 p1, r26, 10            ; 最後が改行でなければ改行する
        BR32 p1, .ret
        ADDI32 r16, r0, 10
        CALL32 putc
        JMP32 .ret
.missing:
        ADDI32 r16, r0, s_missing
        CALL32 puts
        JMP32 .ret
.err:   CALL32 ferr
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        ADDI32 sp, sp, 16
        RET32

; COPY 元 先：ファイルを写す。元が CON ならキーボードから（Ctrl-Z で終わり）
cmd_copy:
        ADDI32 sp, sp, -24
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        STORE32_32 r26, sp, 12
        STORE32_32 r27, sp, 16
        ADDR32 r24, r16, r0             ; r24 = 元
        CALL32 cutword
        ADDR32 r25, r16, r0             ; r25 = 先
        LOAD8U_32 r16, r24, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .missing
        LOAD8U_32 r16, r25, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .missing
        ADDR32 r16, r24, r0             ; 元が CON か
        CALL32 is_con
        CMPNEI32 p1, r16, 0
        BR32 p1, .con
        ADDR32 r16, r24, r0             ; 同じファイルへは写さない
        CALL32 to83
        LOAD32_32 r16, r0, name83
        STORE32_32 r16, r0, newname
        LOAD32_32 r16, r0, name83 + 4
        STORE32_32 r16, r0, newname + 4
        LOAD32_32 r16, r0, name83 + 8
        STORE32_32 r16, r0, newname + 8
        ADDR32 r16, r25, r0
        CALL32 to83
        ADDI32 r16, r0, 0
.same:  LOAD8U_32 r17, r16, name83
        LOAD8U_32 r18, r16, newname
        CMPNER32 p1, r17, r18
        BR32 p1, .diff
        ADDI32 r16, r16, 1
        CMPLTI32 p1, r16, 11
        BR32 p1, .same
        ADDI32 r16, r0, s_onto
        CALL32 puts
        JMP32 .zero
.diff:  ADDR32 r16, r24, r0
        ADDI32 r17, r0, 0
        CALL32 f_open
        CMPLTI32 p1, r16, 0
        BR32 p1, .srcerr
        ADDR32 r26, r16, r0             ; r26 = 元のハンドル
        ADDR32 r16, r25, r0
        ADDI32 r17, r0, 1
        CALL32 f_open
        CMPLTI32 p1, r16, 0
        BR32 p1, .dsterr
        ADDR32 r27, r16, r0             ; r27 = 先のハンドル
.l:     ADDR32 r16, r26, r0
        ADDI32 r17, r0, COPYBUF
        ADDI32 r18, r0, 512
        CALL32 f_read
        CMPLTI32 p1, r16, 1
        BR32 p1, .done
        ADDR32 r18, r16, r0
        STORE32_32 r18, r0, tmp
        ADDR32 r16, r27, r0
        ADDI32 r17, r0, COPYBUF
        CALL32 f_write
        LOAD32_32 r18, r0, tmp
        CMPEQR32 p1, r16, r18
        BR32 p1, .l
        ADDI32 r16, r0, s_diskfull
        CALL32 puts
.done:  ADDR32 r16, r26, r0
        CALL32 f_close
        ADDR32 r16, r27, r0
        CALL32 f_close
        JMP32 .one
.dsterr:
        ADDR32 r16, r26, r0
        CALL32 f_close
        ADDI32 r16, r0, s_createerr
        CALL32 puts
        JMP32 .zero
.srcerr:
        CALL32 ferr
.zero:  ADDI32 r16, r0, s_copied0
        CALL32 puts
        JMP32 .ret
.con:   ADDR32 r16, r25, r0             ; COPY CON ファイル
        CALL32 copy_con
        CMPEQI32 p1, r16, 0
        BR32 p1, .zero
.one:   ADDI32 r16, r0, s_copied1
        CALL32 puts
        JMP32 .ret
.missing:
        ADDI32 r16, r0, s_missing
        CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        LOAD32_32 r26, sp, 12
        LOAD32_32 r27, sp, 16
        ADDI32 sp, sp, 24
        RET32

; is_con(r16 = 名前) → r16 = "CON"（大文字小文字は問わない）なら 1
is_con:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        CALL32 to83
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        ADDI32 r19, r0, 0
.l:     LOAD8U_32 r17, r19, name83
        LOAD8U_32 r18, r19, x_con
        CMPNER32 p1, r17, r18
        BR32 p1, .no
        ADDI32 r19, r19, 1
        CMPLTI32 p1, r19, 11
        BR32 p1, .l
        ADDI32 r16, r0, 1
        JMP32 .ret
.no:    ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; copy_con(r16 = 名前) → r16 = 1 なら書けた。キーボードから 1 行ずつ。Ctrl-Z（と Enter）で終わり
copy_con:
        ADDI32 sp, sp, -16
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        STORE32_32 r25, sp, 8
        ADDI32 r17, r0, 1
        CALL32 f_open
        CMPLTI32 p1, r16, 0
        BR32 p1, .fail
        ADDR32 r24, r16, r0             ; r24 = ハンドル
.line:  ADDI32 r25, r0, 0               ; r25 = この行の長さ（conbuf の中）
.key:   CALL32 BIOS_GETC
        CMPEQI32 p1, r16, 0x1A          ; Ctrl-Z
        BR32 p1, .eof
        CMPEQI32 p1, r16, 13
        BR32 p1, .enter
        CMPEQI32 p1, r16, 10
        BR32 p1, .key
        CMPEQI32 p1, r16, 8
        BR32 p1, .bs
        CMPEQI32 p1, r16, 127
        BR32 p1, .bs
        CMPLTUI32 p1, r16, 32
        BR32 p1, .key
        CMPGEI32 p1, r25, 126
        BR32 p1, .key
        STORE8_32 r16, r25, conbuf
        ADDI32 r25, r25, 1
        CALL32 BIOS_PUTC
        JMP32 .key
.bs:    CMPEQI32 p1, r25, 0
        BR32 p1, .key
        ADDI32 r25, r25, -1
        ADDI32 r16, r0, 8
        CALL32 BIOS_PUTC
        JMP32 .key
.enter: ADDI32 r16, r0, 13              ; 行の終わりは \r\n
        STORE8_32 r16, r25, conbuf
        ADDI32 r16, r0, 10
        STORE8_32 r16, r25, conbuf + 1
        ADDI32 r25, r25, 2
        CALL32 BIOS_PUTC
        ADDR32 r16, r24, r0
        ADDI32 r17, r0, conbuf
        ADDR32 r18, r25, r0
        CALL32 f_write
        JMP32 .line
.eof:   ADDI32 r16, r0, s_ctrlz
        CALL32 BIOS_PUTS
        ADDR32 r16, r24, r0             ; 打ちかけの行も書く
        ADDI32 r17, r0, conbuf
        ADDR32 r18, r25, r0
        CALL32 f_write
        ADDR32 r16, r24, r0
        CALL32 f_close
        ADDI32 r16, r0, 1
        JMP32 .ret
.fail:  ADDI32 r16, r0, s_createerr
        CALL32 puts
        ADDI32 r16, r0, 0
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        LOAD32_32 r25, sp, 8
        ADDI32 sp, sp, 16
        RET32

; DEL ファイル名
cmd_del:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .missing
        CALL32 f_delete
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        CALL32 ferr
        JMP32 .ret
.missing:
        ADDI32 r16, r0, s_missing
        CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

; REN 前の名前 新しい名前
cmd_ren:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDR32 r24, r16, r0
        CALL32 cutword
        ADDR32 r17, r16, r0
        LOAD8U_32 r16, r17, 0
        CMPEQI32 p1, r16, 0
        BR32 p1, .missing
        ADDR32 r16, r24, r0
        CALL32 f_rename
        CMPEQI32 p1, r16, 0
        BR32 p1, .ret
        CMPEQI32 p1, r16, -7
        BR32 p1, .nr
        ADDI32 r16, r0, s_dupname
        CALL32 puts
        JMP32 .ret
.nr:    CALL32 ferr
        JMP32 .ret
.missing:
        ADDI32 r16, r0, s_missing
        CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        LOAD32_32 r24, sp, 4
        ADDI32 sp, sp, 8
        RET32

; TIME：起動してからの時間（タイマーは 1µs ごとに増える）
cmd_time:
        ADDI32 sp, sp, -8
        STORE32_32 lr, sp, 0
        STORE32_32 r24, sp, 4
        ADDI32 r16, r0, s_uptime
        CALL32 puts
        LOAD32_32 r24, r0, TIMER_COUNT
        DIVUI32 r16, r24, 1000000
        CALL32 putdec
        ADDI32 r16, r0, '.'
        CALL32 putc
        DIVUI32 r24, r24, 1000          ; ミリ秒を 3 桁で
        REMUI32 r16, r24, 1000
        ADDI32 r16, r16, 1000
        ADDI32 r17, r0, 0
        CALL32 fmtdec
        ADDI32 r16, r16, 1
        CALL32 puts
        ADDI32 r16, r0, s_sec
        CALL32 puts
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
        CALL32 puts
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
        CALL32 puts
.ret:   LOAD32_32 lr, sp, 0
        ADDI32 sp, sp, 8
        RET32

s_banner:   .asciz "MyDOS Version 3.0\n(C)Copyright MyCPU Project 2026.\n"
s_prompt:   .asciz "C:\\>"
s_bad:      .asciz "Bad command or file name\n"
s_ver:      .asciz "\nMyDOS Version 3.0 (MyCPU-32, FAT16/FAT32)\n"
s_help:     .ascii "CLS       Clears the screen.\n"
            .ascii "COLOR xy  Sets colors (x = background, y = text, hex). COLOR alone resets.\n"
            .ascii "COPY      Copies a file. COPY CON name creates a file from the keyboard (end with Ctrl-Z).\n"
            .ascii "DEL       Deletes a file.\n"
            .ascii "DIR       Displays the files on drive C: (SD card).\n"
            .ascii "ECHO      Displays a message.\n"
            .ascii "LED xx    Turns the board LEDs on/off (hex).\n"
            .ascii "MEM       Displays the memory map.\n"
            .ascii "REBOOT    Restarts the computer.\n"
            .ascii "REN       Renames a file.\n"
            .ascii "SHUTDOWN  Halts the CPU.\n"
            .ascii "TIME      Displays the time since boot.\n"
            .ascii "TYPE      Displays the contents of a text file.\n"
            .ascii "VER       Displays the MyDOS version.\n"
            .ascii "VOL       Displays the volume label and serial number.\n"
            .ascii "To run a program, type its name (.EXE, .COM or .BAT on drive C:).\n"
            .asciz "Add > file or >> file to a command to send its output to a file.\n"
s_vol1:     .asciz " Volume in drive C is "
s_vol2:     .asciz "\n Volume Serial Number is "
s_dirof:    .asciz " Directory of C:\\\n\n"
s_dirtag:   .asciz "    <DIR>  "
s_sp2:      .asciz "  "
s_files:    .asciz " file(s)"
s_bytes:    .asciz " bytes\n"
s_free:     .asciz " bytes free\n"
s_freekb:   .asciz " KB free\n"
s_notready: .asciz "Not ready reading drive C\n"
s_notfound: .asciz "File not found\n"
s_missing:  .asciz "Required parameter missing\n"
s_denied:   .asciz "Access denied\n"
s_toomany:  .asciz "Too many open files\n"
s_diskfull: .asciz "Insufficient disk space\n"
s_createerr: .asciz "File creation error\n"
s_readerr:  .asciz "Read error reading drive C\n"
s_toobig:   .asciz "Program too big to fit in memory\n"
s_badexe:   .asciz "Invalid EXE file\n"
s_dupname:  .asciz "Duplicate file name or file not found\n"
s_onto:     .asciz "File cannot be copied onto itself\n"
s_copied0:  .asciz "        0 file(s) copied\n"
s_copied1:  .asciz "        1 file(s) copied\n"
s_ctrlz:    .asciz "^Z\n"
s_term:     .asciz "\nProgram terminated: "
s_fault_align: .asciz "alignment error"
s_fault_priv:  .asciz "privileged instruction"
s_fault_div:   .asciz "divide by zero"
s_fault_other: .asciz "exception"
s_at:       .asciz " at "
s_mem:      .ascii "\n   49152 bytes total memory\n"
            .ascii "   24576 bytes for MyDOS    (0x20000-0x25FFF)\n"
            .ascii "   20480 bytes for programs (0x26000-0x2AFFF)\n"
            .asciz "    4096 bytes for BIOS     (0x2B000-0x2BFFF)\n"
s_mem_sdram: .asciz " bytes SDRAM        (0x1000000-0x17FFFFF, free for programs)\n"
s_uptime:   .asciz "Uptime: "
s_sec:      .asciz " seconds\n"
s_color_usage: .asciz "Usage: COLOR xy  (x = background, y = text, 0-F)\n"
s_led_usage:   .asciz "Usage: LED xx  (hex, lower 6 bits)\n"
s_safe:     .asciz "\n\n          It's now safe to turn off your computer.\n"
s_autoexec: .asciz "AUTOEXEC.BAT"
badchars:   .asciz "*?/\\:\"<>|+=,;[]"
x_exe:      .ascii "EXE"
x_com:      .ascii "COM"
x_bat:      .ascii "BAT"
x_con:      .ascii "CON        "
exts:       .ascii "EXE\0COM\0BAT\0\0"
c_cls:      .asciz "CLS"
c_color:    .asciz "COLOR"
c_copy:     .asciz "COPY"
c_del:      .asciz "DEL"
c_erase:    .asciz "ERASE"
c_dir:      .asciz "DIR"
c_echo:     .asciz "ECHO"
c_help:     .asciz "HELP"
c_led:      .asciz "LED"
c_mem:      .asciz "MEM"
c_reboot:   .asciz "REBOOT"
c_ren:      .asciz "REN"
c_rename:   .asciz "RENAME"
c_shutdown: .asciz "SHUTDOWN"
c_time:     .asciz "TIME"
c_type:     .asciz "TYPE"
c_ver:      .asciz "VER"
c_vol:      .asciz "VOL"

; ---- 変数（起動時に 0 にする。MYDOS.SYS には入らない） ----
        .align 4
bss_start:
fs_ok:      .reserve 4
exehdr:     .reserve 16                 ; .EXE のヘッダ
prog_base:  .reserve 4                  ; 実行中のプログラムを読み込んだ番地
fs_type:    .reserve 4
fat_lba:    .reserve 4
fat_sz:     .reserve 4
nfats:      .reserve 4
root_lba:   .reserve 4
root_secs:  .reserve 4
root_clus:  .reserve 4
data_lba:   .reserve 4
spc:        .reserve 4
clus_bytes: .reserve 4
nclus:      .reserve 4
fs_serial:  .reserve 4
fs_free:    .reserve 4
free_hint:  .reserve 4
fsinfo_lba: .reserve 4
sb_lba:     .reserve 4
sb_dirty:   .reserve 4
fc_sec:     .reserve 4
fc_dirty:   .reserve 4
d_lba:      .reserve 4
d_left:     .reserve 4
d_clus:     .reserve 4
d_idx:      .reserve 4
d_cur:      .reserve 4
d_end:      .reserve 4
e_lba:      .reserve 4
e_off:      .reserve 4
f_lba:      .reserve 4
f_off:      .reserve 4
lfn_n:      .reserve 4
lfn:        .reserve 160
bat_ptr:    .reserve 4
bat_end:    .reserve 4
redir_h:    .reserve 4
quiet:      .reserve 4
running:    .reserve 4
saved_sp:   .reserve 4
saved_attr: .reserve 4
tmp:        .reserve 4
args:       .reserve 4
handles:    .reserve 32 * NFILES
ent:        .reserve 32
dent:       .reserve 32
name83:     .reserve 12
newname:    .reserve 12
vol_label:  .reserve 12
numbuf:     .reserve 12
cbuf:       .reserve 4
linebuf:    .reserve 128
batargs:    .reserve 128
cmdbuf:     .reserve 128
conbuf:     .reserve 128
bss_end:
