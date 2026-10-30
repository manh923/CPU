# MyCPU

`isa-spec.md`（命令セット仕様書 v0.9）と `opcodes.csv` から作った、アセンブラ・シミュレータ・Verilog（32bit 版、Tang Nano 20K 向け）。

| 場所 | 中身 |
|---|---|
| `opcodes.csv` | 全命令の表。ほかはすべてここから作る（`tools/gen.js`） |
| `asm/asm.js` | アセンブラ（コマンドライン） |
| `sim/sim.js` | シミュレータ（コマンドライン。キー入力・画面表示つき） |
| `web/index.html` | シミュレータ（ブラウザ。ファイルを直接開くだけで動く） |
| `lib/` | アセンブラ・CPU・表示の本体（Node とブラウザで共通） |
| `examples/` | 例題（`bios.asm` は ROM に入れる BIOS ＋ブートローダー） |
| `disk/` | SD カードの中身のもと（MyDOS 本体 `mydos.sys.asm` も。`tools/mkdisk.js` で作る） |
| `cc/` | C コンパイラ（chibicc をこの CPU 向けに改造したもの）。`cc/README.md` |
| `libc/` | C ライブラリ（`printf`・文字列・`malloc` など）と、ヘッダ |
| `tools/cc.js` | C のプログラムを MyDOS の `.EXE` にする |
| `tools/mkboot.js` | UART 起動で送るファイルを作る |
| `tools/mkdisk.js` | SD カードの中身（ファイルかディスクイメージ）を作る |
| `rtl/` | Verilog（CPU・メモリ・入出力・UART・表示回路・DVI 符号器） |
| `rtl/gowin/` | Tang Nano 20K 用のトップとピン割り当て |
| `tb/` | Verilog のテストベンチ |
| `font/` | 8×16 フォント（`tools/gen_font.py` で作り直せる） |
| `test/run.js` | テスト一式 |

必要なもの：Node.js 18 以上。Verilog のテストには Icarus Verilog（`iverilog`）。

## 使い方

```sh
cd mycpu
node asm/asm.js examples/hello.asm          # → hello.bin / hello.lst / hello.hex
node sim/sim.js examples/hello.asm          # .asm を直接渡してもよい
node sim/sim.js examples/bios.asm --sd disk/ --screen    # BIOS → SD カードの MYDOS.SYS。HELP でコマンド一覧
node sim/sim.js examples/console.asm --screen   # 画面（VRAM）を端末に表示。キー入力はその場で届く。Ctrl-] で終了
node sim/sim.js examples/selftest64.asm --cpu 64
node sim/sim.js examples/colors.asm --png screen.png   # 止まったときの画面を PNG に
node test/run.js                            # テスト一式
```

`sim.js` のオプション：`--cpu 32|64`、`--trace`（1 命令ずつ表示）、`--max N`、`--input 文字列`（UART 受信に入れておく）、`--rx-file ファイル`（同じくファイルの中身）、`--sd フォルダ|.img`（SD カードを挿す）、`--sd-save 名前`（止まったときの SD カードを .img で保存）、`--screen`、`--png`／`--ppm`、`--regs ファイル|-`、`--realtime`（タイマーを実時間で進める）。

ブラウザ版は `web/index.html` を開く。左で書いて「アセンブルして実行」。画面（または UART の欄）をクリックしてからキーを押すと、その場で UART 受信に届く。Ctrl+Enter でも実行できる。

## アセンブラの書き方

```asm
UART_TX = 0x00010000            ; 定数（.equ UART_TX, 0x00010000 も可）
start:  ADDI32 sp, r0, 0x00028000
.loop:  LOAD8U_32 r17, r16, 0   ; '.' で始まるラベルは直前のラベルの中だけで有効
        CMPEQI32 p1, r17, 0
        BR32 p1, .done
        STORE32_32 r17, r0, UART_TX
        ADDI32 r16, r16, 1
        JMP32 .loop
.done:  HLT
msg:    .asciz "hi\n"
```

- 命令名とオペランドの並びは `opcodes.csv` のとおり（例：`STORE32_32 rs2, rs1, imm`、`SEL32 rd, rs1, rs2, p`）
- レジスタの別名：`pc sp lr epc cause evec status`、1bit レジスタは `p1`〜`p7` とも書ける
- 数値：`0x`、`0b`、10 進、`'A'`。即値には `+ - * / % << >> & | ^ ~ ( )` の式が書ける
- 疑似命令：`.org .align .space .byte .half .word .dword .ascii .asciz .equ .phase .dephase`
- `.phase 番地` 〜 `.dephase`：中身はその場所（ROM）に置き、ラベルは「番地」（RAM）に写して動かす前提で決める。`.phase` の前は `.align 16`
- 命令は自動で 4 バイト境界にそろう。幅の合わないレジスタ・予備レジスタ・PC への書き込みはエラー

## C で書く

```sh
node tools/cc.js disk/primes.c -o PRIMES.EXE     # C → MyDOS の .EXE（SDRAM で動く）
node tools/cc.js disk/primes.c -S primes.asm     # アセンブリだけ（C ライブラリ込み）
node test/cctest.js                              # コンパイラのテスト（chibicc のテスト）
```

- コンパイラは `cc/`（chibicc の改造版）。`gcc` と `make` で自動でビルドされる。`int`・`long`・ポインタは 32bit、`long long` は 64bit。`float` は 32bit、`double`・`long double` は 64bit（IEEE 754。計算はソフトウェアで、`libc/softfloat.c`）。使わない関数・変数はつながない（`tools/cc.js` がリンカの代わりに捨てる）
- C ライブラリ（`libc/`）：
  - `stdio.h`：`FILE`（`fopen`・`fread`・`fwrite`・`fgets`・`fputs`・`fseek`・`ftell`・`fprintf` …。書くファイルは後ろに足すだけなので、`fseek` できるのは読むファイル）、`stdin`（1 行ずつ）・`stdout`・`stderr`、`printf` の仲間（`%lld` も）、`scanf`・`fscanf`・`sscanf` と v の付いたもの（`libc/scanf.c`。glibc と同じ結果になるかをテストで比べる）、`remove`・`rename`・`perror`
  - `printf` の `%f`・`%e`・`%g` と `strtod`・`atof` は正しく丸める（`libc/fltio.c`）
  - `math.h`（`libc/math.c`）：`sqrt`・`fmod`・`floor`・`ceil`・`round` などは正確、`sin`・`cos`・`tan`・`atan2`・`exp`・`log`・`pow` などは誤差 2 ulp 以内。`float` の版（`sinf` など）もある
  - `stdlib.h`（`malloc`・`free`・`realloc`・`exit`・`strtol`・`strtoll`・`strtoull`・`strtod`・`qsort`・`rand`）、`string.h`、`ctype.h`、`errno.h`、`limits.h`、`stdint.h`、`inttypes.h`、`assert.h`、`setjmp.h`、`time.h`（時計がないので 2026-01-01 から起動後の秒数）、`stdarg.h`・`stddef.h`・`stdbool.h`
  - `conio.h`：`clrscr`・`gotoxy`・`textattr`・`getch`（矢印・Home・End・PgUp・PgDn・Delete・F1〜F4 を 1 つのキーに）・`kbhit`
  - `mycpu.h`：MyDOS の SYSCALL を直接呼ぶ
  - `unistd.h`・`sys/stat.h`：`mkdir`・`rmdir`・`chdir`・`getcwd`・`stat`・`access` など。ファイル名はディレクトリ付きでよい（`/` も `\` も。名前は 1 つずつ 8.3 に縮める）
  - テストは `test/libtest.c`（MyDOS の上で動かす）
- `disk/` に `NAME.c` を置くと、mkdisk・`sim.js --sd disk/`・ブラウザ版の SD カードに `NAME.EXE` も入る（`disk/primes.c` → `PRIMES.EXE`）。ブラウザではコンパイルできないので、ブラウザ版で `.c` を書き換えても `.EXE` は変わらない
- **`AS`**（`disk/as.c`）：C で書いたアセンブラ。MyDOS の上で `AS -o OUT.EXE FILE.S ...` と使う（`-bin` でそのままのバイト列、`-b 番地` で最初の番地）。書き方は `lib/assembler.js` と同じで、同じバイト列を作る（テストで比べている）。ファイルをいくつも渡すと、コードとデータを分けて並べ直してつなぐ（リンカの代わり。C のプログラムなら `-b 0x1000000`）。命令の表 `disk/asops.h` は `tools/gen.js` が作る
- MyDOS の上の CC：カードの `INCLUDE\` にヘッダ、`LIB\` に `CRT0.S`・`LIBC.*`、`SRC\CC\` に chibicc のソース。`BUILD NAME` で `NAME.C` → `NAME.EXE`、`SELFHOST CC CC2` で CC 自身を `C:\CC2.EXE` に作り直す
- **`EDIT 名前`**（`disk/edit.c`）：全画面のテキストエディタ。80 桁 × 24 行なので、UART の端末でもそのまま使える。矢印・Home・End・PgUp・PgDn・Backspace・Delete・Tab、**Ctrl-S で保存、Ctrl-X で終わり**（保存していなければ聞く）。保存は CRLF

## BIOS と MyDOS

ROM（16KB）に入っているのは BIOS（`examples/bios.asm`）だけ。MyDOS は SD カードの `MYDOS.SYS`（`disk/mydos.sys.asm`）。

1. **BIOS**：見出し、メモリテスト（内蔵 RAM 40KB を 1KB ずつ書いて読み戻す）、SDRAM の検査（データ線とアドレス線）、SD カードの初期化、SYSCALL の表の初期化
2. 1 秒だけ **U キー**を待つ。U なら UART から起動、ほかのキーか時間切れなら次へ
3. **ブートローダー**：SD カードの FAT のルートから `MYDOS.SYS` を探し、`0x20000` に読み込んで飛ぶ。カードがない・`MYDOS.SYS` がないときは `Non-System disk or disk error` を出し、キーを待ってやり直す
4. **MyDOS 3.0**：`AUTOEXEC.BAT` があれば実行して `C:\>` を出す

### MyDOS

ドライブ C: は microSD カード（SPI モード）の FAT16 / FAT32。サブディレクトリも使える（`C:\INCLUDE\STDIO.H`、`..`、`/` でも区切れる）。**読み書きできる**。PC で FAT にフォーマットしたカードに `MYDOS.SYS` を写せば起動する（書き込みを試すときは、消えて困るもののないカードで）。

- 組み込みのコマンド：`DIR`（`DIR SRC\CC` のようにディレクトリも）、`CD`／`CHDIR`、`MD`／`MKDIR`、`RD`／`RMDIR`、`TYPE`、`COPY`（`COPY CON 名前` でキーボードから。Ctrl-Z で終わり）、`DEL`／`ERASE`、`REN`／`RENAME`、`VOL`、`VER`、`CLS`、`ECHO`、`MEM`、`TIME`、`COLOR 1F`、`LED 2A`、`HELP`、`REBOOT`、`SHUTDOWN`
- `コマンド > 名前`・`コマンド >> 名前`：画面に出るものをファイルへ（プログラムの出力も）
- それ以外は SD カードから探して実行する：名前だけなら `.EXE` → `.COM` → `.BAT` の順
  - `.EXE`：先頭 16 バイトがヘッダ（`'MZ'`、ヘッダの大きさ 2 バイト、読み込む番地・開始番地・本体の大きさ 各 4 バイト）。読み込む番地は `0x26000`（8KB まで）か SDRAM の `0x1000000`〜（`0x17EFFFF` まで。スタックもその終わり `0x17F0000` から。`BIG.EXE`）。
    ヘッダの大きさの欄が `0x8010` なら区切りのある .EXE（`AS -lib` が作る。C ライブラリのうち使う関数だけを、元の番地のまま入れる）：本体は「番地・長さ（4 バイトずつ）・中身」の並び
  - `.COM`：ヘッダなし。`0x26000` に置いてそのまま実行
  - `.BAT`：1 行ずつコマンドとして実行（`@` で始まる行は表示しない。別の `.BAT` を実行するとそちらへ移る）
  - プログラムは**ユーザーモード**で動き、OS を呼ぶのは SYSCALL だけ。r16 に引数の文字列を受け取り、`RET32` か SYSCALL 0 で `C:\>` に戻る。例外（0 で割る、整列していない読み書き、特権命令など）を起こすと `Program terminated: …` を出して `C:\>` に戻る（`CRASH.EXE`）。大きさは、`0x26000` に置くものは 8KB（`0x26000`〜`0x27FFF`）まで、SDRAM に置くものは `0x17EFFFF` まで（8MB − 64KB）
- 書き込み：空きクラスタを探して FAT を 2 つとも書き、FAT32 は FSInfo（空きの数）も直す。FAT32 のルートがいっぱいならクラスタを足す。長い名前のファイルを消す・名前を変えるときは、長い名前の項目も消す。日付は時計がないので 2026-01-01
- パーティション表あり（普通の SD カード）・なし（`mkfs.fat` でそのまま作ったもの）のどちらも使える。長いファイル名は 8.3 の名前で扱う。プログラムは今のディレクトリ → ルートの順に探す（パスを書いたときはそこだけ）
- 未対応：FAT12、1 セクタ 512 バイト以外、時計

### SYSCALL（x86 の INT にあたる）

r23 に番号、引数は r16〜r19 に入れて `SYSCALL`。戻り値は r16（エラーは負の数）。CPU は BIOS の例外の入口に飛び、BIOS が RAM の表（`0x2B100`、4 バイト × 64）のその番号の番地を呼ぶ。表は RAM にあるので書き換えて機能を差し替えられる。BIOS が 1〜10 を登録し、MyDOS が 0・16〜21・23〜26 を足して、画面に出す 1・2・6・7・8 をリダイレクトできる自分の版に差し替える。

| 番号 | 機能 |
|---|---|
| 0 | 終了 |
| 1 / 2 | putc(文字) / puts(文字列) |
| 3 / 4 | getc() → 文字 / getline(置き場所, 最大) → 長さ |
| 5 | cls() |
| 6 / 7 | putdec(数) / puthex(数) |
| 8 | putg(文字)：制御文字も字の形のまま |
| 9 | setattr(色) → 前の色 |
| 10 | kbhit() → キーが来ていれば 1 |
| 16 | open(名前, モード) → ハンドル（0 = 読む、1 = 新しく書く、2 = 後ろに足す。同時に 4 つまで） |
| 17 | close(ハンドル) |
| 18 | read(ハンドル, 置き場所, 長さ) → 読んだ長さ（0 で終わり） |
| 19 | write(ハンドル, データ, 長さ) → 書いた長さ |
| 20 / 21 | delete(名前) / rename(前の名前, 新しい名前) |
| 23 / 24 | mkdir(パス) / rmdir(パス)（空のディレクトリだけ） |
| 25 / 26 | chdir(パス) / getcwd(置き場所, 大きさ) → 長さ（`C:\SRC\CC` の形） |

エラー：-1 番号がない・ハンドルが違う、-2 ファイルがない、-3 開きすぎ、-4 空きがない、-5 できない（ディレクトリ・読み出し専用・同じ名前がある）、-6 名前が正しくない、-7 カードが読めない。使い方の例は `disk/toupper.exe.asm`（ファイルを読んで大文字にして書く）。

### メモリの配置（内蔵 RAM 40KB）

| 番地 | 中身 |
|---|---|
| `0x20000`〜`0x25FFF` | MYDOS.SYS の前半（変数も含めて 24KB まで。BIOS が読むのはここだけ） |
| `0x26000`〜`0x27FFF` | プログラム（.EXE・.COM） |
| `0x28000`〜`0x29FFF` | なし（この分の BSRAM はデータキャッシュに使っている。読み書きするとバスエラー） |
| `0x2A000`〜`0x2AFFF` | 空き（データだけ。ここから後ろは命令を読めない） |
| `0x2B000`〜 | BIOS の変数、`0x2B100` SYSCALL の表、`0x2B200` セクタの置き場、`0x2B400` FAT の置き場、`0x2B600` .BAT の置き場 |
| 〜`0x2BFFF` | スタック（SP の初期値 `0x2C000`） |
| `0x1000000`〜`0x17EFFFF` | SDRAM（8MB のうち 64KB を除く）。`.org 0x1000000` で書いた `.EXE` はここに読み込まれ、スタックも末尾に置かれる。ほかのプログラムも自由に使ってよい（`disk/sieve.exe.asm` は 1MB のふるいに使う）。`MEM` に出る |
| `0x17F0000`〜`0x17FFFFF` | MyDOS の後半（MYDOS.SYS の 24KB から後ろ。サブディレクトリ・`CD`・`MD`・`RD` など。前半が起動時に読み込む） |

### SD カードの中身を作る

`disk/` に入れる中身がある（`MYDOS.SYS`、`README.TXT`、`AUTOEXEC.BAT`、`DEMO.BAT`、`HELLO.EXE`、`FIB.EXE`、`MANDEL.EXE`、`SIEVE.EXE`、`BIG.EXE`、`TOUPPER.EXE`、`CRASH.EXE`、`KITT.COM` のもと）。`NAME.exe.asm`・`NAME.com.asm` は `.EXE`・`.COM` に（`.org 0x26000` で書く。`.EXE` は `.org 0x1000000` なら SDRAM 用）、`NAME.sys.asm` は `.SYS` に（`.org 0x20000`）アセンブルされる。

```sh
node tools/mkdisk.js --files sdcard/           # ファイルを作る → FAT でフォーマットした SD カードに PC から写す
node tools/mkdisk.js -o disk.img [--fat32]     # ディスクイメージを作る（シミュレータ用）
node sim/sim.js examples/bios.asm --sd disk/ --screen    # フォルダを渡すと、その場でイメージを作って挿す
node sim/sim.js examples/bios.asm --sd disk.img --sd-save after.img   # 書いた後の中身を保存（元の .img はそのまま）
```

ブラウザ版は、上の「SD：」から disk/ の中身（FAT16 / FAT32）、なし、手元の `.img` を選べる。同じページで続けて実行すると、書いた中身は残る。「SD を保存」で `.img` として保存できる。

ブラウザ版の左の欄で書けるのは 2 種類。いちばん左の選択で切り替える：

- **ROM に入れる**（`examples/`）：選んだものが ROM になる。MyDOS を動かすなら `bios.asm`
- **SD カードのファイル**（`disk/`）：`hello.exe.asm`・`mydos.sys.asm`・`AUTOEXEC.BAT` など。書き換えると、次の実行で SD カードを作り直して入れる（ROM は最後に選んだもののまま）。「新しいファイル」で `PROG.exe.asm` などを足せる（ひな形つき）。アセンブルのエラーはファイル名つきで出る

### BIOS の入口

カーネルモードのもの（MyDOS など）は、ROM の決まった番地を `CALL32` しても BIOS を使える。

| 番地 | 機能 |
|---|---|
| `0x10` | putc(r16 = 文字)。`\n` 改行、`\r` 行頭へ、`\b` 1 文字戻って消す |
| `0x18` | puts(r16 = 文字列) |
| `0x20` | getc() → r16 |
| `0x28` | getline(r16 = 置き場所, r17 = 最大の長さ) → r16 = 長さ |
| `0x30` | cls() |
| `0x38` | putdec(r16) |
| `0x40` | puthex(r16) |
| `0x48` | 再起動 |
| `0x50` | putg(r16)：制御文字も字の形のまま画面に出す |
| `0x58` | sd_init() → r16 = カードの種類（0 = なし、1・2 = SDSC、3 = SDHC/SDXC） |
| `0x60` | sd_read(r16 = セクタ番号, r17 = 置き場所 512 バイト) → r16 = 0 なら成功 |
| `0x68` | sd_write(r16 = セクタ番号, r17 = 512 バイト) → r16 = 0 なら成功 |
| `0x70` | kbhit() → r16 = キーが来ていれば 1 |
| `0x78` | setattr(r16 = 色) → r16 = 前の色 |

### UART から起動

起動中に U を押すと、`'MC'`＋長さ（4 バイト）＋本体 を受け取って `0x20000` に置き（44KB まで）、カーネルモードのままそこへ飛ぶ。プログラムは `.org 0x20000` で書く（`examples/uartboot/hello_uart.asm`）。

```sh
node tools/mkboot.js examples/uartboot/hello_uart.asm -o hello.boot
node sim/sim.js examples/bios.asm --input u --rx-file hello.boot   # シミュレータで試す
```

実機では、U を押してから端末ソフトのバイナリ送信で `hello.boot` を送る。ブラウザ版は「UART 受信へファイルを送る」から送る。

## 仕様書で決まっていないところ（仮決め）

シミュレータと Verilog は同じ決め方にしてある。

**入出力**（`0x0001_0000` から。どれも 32bit。決まった番地以外は 0 を読み、書き込みは無視。書き込みはレジスタの先頭バイトを含むときだけ効く）

| 番地 | 名前 | 内容 |
|---|---|---|
| `+0x00` | UART_TX | 書くと下位 8bit を送る |
| `+0x04` | UART_STATUS | bit0 = 送れる（送信 FIFO に空きあり）、bit1 = 受信データあり |
| `+0x08` | UART_RX | 読むと受信データを 1 バイト取り出す（なければ 0） |
| `+0x10` | TIMER_COUNT | 1µs ごとに増える 32bit カウンタ（書くとその値から数え直す） |
| `+0x14` | TIMER_CMP | 比べる値 |
| `+0x18` | TIMER_CTRL | bit0 = 割り込みを出す、bit1（読むだけ）= COUNT − CMP ≥ 0（符号付き）で割り込み中 |
| `+0x20` | LED | 下位 6bit が基板の LED |
| `+0x30` | SD_DATA | 書くと SPI で 1 バイト送り（同時に受け取る）、読むと受け取った 1 バイト |
| `+0x34` | SD_CTRL | bit0 = CS（1 でカードを選ぶ）、bit15〜8 = SCK の分周（半周期 = 分周 + 1 クロック） |
| `+0x38` | SD_STATUS | bit0 = 送受信中 |

- 外部割り込み：0 = UART 受信データあり、1 = タイマー（どちらもレベル。原因がなくなるまで続く）
- UART は 115200bps・8N1。送信・受信とも 16 バイトの FIFO
- シミュレータのタイマーは、既定では 1 命令 = 1µs として進む（毎回同じ結果になるように）。`--realtime` とブラウザ版は実時間
- STATUS で実装している bit は 0〜3 と 8〜15。ほかは 0 を読む
- 「HLT にする」とされている不正命令は、どちらも止まって理由を出す（Verilog は LED5・LED4 に出す）。つながっていない番地や ROM への書き込みも止まる
- 1bit レジスタをアドレスに使ったときも止まる（仕様の 3.3 では決まっていない）
- テキスト VRAM：1 行 160 文字（320 バイト）、色は CGA/VGA の標準 16 色
- SDRAM：`0x0100_0000`〜`0x017F_FFFF`（8MB）。シミュレータは待ち時間なし。Verilog は命令キャッシュとデータキャッシュを通す（下の「キャッシュ」）

## FPGA（Tang Nano 20K）

32bit 版 CPU、ROM 16KB・内蔵 RAM 40KB・VRAM 16KB・命令キャッシュ 8KB・データキャッシュ 8KB（BSRAM）、SDRAM 8MB（チップの中のもの）、UART、タイマー、LED、microSD（SPI）、720p のテキスト画面（HDMI 端子から DVI で出す）。CPU は 27MHz の 3 段パイプラインで、ふつうの命令は 1 クロック（下の「CPU の速さ」）。

Gowin EDA での手順：

1. 新しいプロジェクト。デバイスは `GW2AR-LV18QN88C8/I7`
2. 追加するファイル：`rtl/cpu.v rtl/soc.v rtl/sdram.v rtl/uart.v rtl/video.v rtl/tmds.v rtl/gowin/top_tangnano20k.v rtl/gowin/tangnano20k.cst`
3. インクルードのパスに `rtl` を追加（`opcodes.vh` のため）。トップモジュールは `top_tangnano20k`
4. ROM の中身：`node asm/asm.js examples/bios.asm -o rom` で `rom_even.hex`・`rom_odd.hex`（偶数番目・奇数番目の 4 バイト）を作る。この 2 つと `font/font8x16.hex` を、合成ツールが `$readmemh` で見つけられる場所（プロジェクトのフォルダ）に置く
5. 合成・配置配線して書き込む。PC 側は 115200bps の端末ソフトでつなぐ
6. SD カード：PC で FAT32（2GB 以下なら FAT16 も可）にフォーマットし、`node tools/mkdisk.js --files sdcard/` で作ったファイル（`MYDOS.SYS` も）をルートに写して挿す

**まだ実機で確かめていない。** ここ（クラウドの環境）では Gowin のツールを動かせないので、確かめたのは Icarus Verilog でのシミュレーションまで：

- CPU：例題をシミュレータと同時に動かし、UART の出力と止まったときのレジスタが全部一致。`examples/pipeline.asm`（衝突をわざと起こすテスト）と `examples/sdram.asm` は、実行した命令の順番も 1 命令ずつ一致
- SDRAM：制御回路を SDRAM のモデル（`tb/sdram_model.v`）につなぎ、ランダムな読み書き 2 万回と 16 語のバースト読み出し 300 回（半分はバースト書き込みで書いたもの）が一致、タイミング違反なし。SoC 全体でも `examples/sdram.asm`（SDRAM でプログラムを実行し、スタックも SDRAM。実行した後のコードを書き換えて、命令キャッシュが古い命令を返さないか）がシミュレータと一致
- SD カード：SPI の回路を、SD カード（SPI モード）のモデル（`tb/sd_model.v`、読み書き）につないで BIOS から `MYDOS.SYS` を起動。FAT16 のイメージで `AUTOEXEC.BAT`・`DIR`・`TYPE`・`COPY CON`・`REN`・`DEL`・ユーザーモードのプログラムと例外まで、シミュレータと一致
- FAT：`mkfs.fat`・`mtools` で作ったイメージ（FAT16・FAT32、パーティション表なし、長い名前、サブディレクトリ）も読め、空き容量も `mdir` と一致。MyDOS で書いた後のイメージは `fsck.fat` でエラーなし、書いたファイルは `mtype` で読める
- 表示回路：1 フレーム（1280×720）を取り込み、シミュレータの絵と 1 ドットまで一致
- TMDS 符号器：符号化したものを元に戻せること、直流の偏りが小さいこと
- トップ：Gowin 部品を代わりのモジュールにしてコンパイルが通ること

### キャッシュ

SDRAM の前に、命令キャッシュとデータキャッシュ（どちらも 8KB）を置く（`rtl/soc.v`）。どちらもダイレクトマップで、1 ライン 64 バイト × 128 ライン、タグはフリップフロップ。外れたら SDRAM からライン 1 本（16 語）をバースト読み出し（行を開いたまま READ を 16 回続ける）で読む。約 24 クロック。

- **命令キャッシュ**：データは偶数番目・奇数番目の 4 バイトに分けて BSRAM に置き、8 バイトの命令を 1 クロックで読む。データの口で SDRAM の番地に書くと、その番地のラインを無効にする。単純なループで 1 命令あたり 12.7 → 1.26 クロック（内蔵 RAM は 1.25）
- **データキャッシュ**：ライトバック・ライトアロケート。当たれば読み書きとも内蔵 RAM と同じ速さ（次のクロックに返す）。外れたとき、今のラインが書き換えられていれば（汚れ）、16 語をバッファに写してバースト書き込み（WRITE を 16 回続ける）で SDRAM に書き戻してから読む
- **2 つのキャッシュの食い違い**：命令キャッシュが読もうとするラインがデータキャッシュで汚れていたら、先に SDRAM へ書き戻させる。命令キャッシュが読んでいる最中のラインへの書き込みは、読み終えるまで待たせる。MyDOS が読み込んだプログラムや、自分を書き換えるコードも、プログラムからはキャッシュがないのと同じに見える
- BSRAM は 46 ブロックを使い切っているので、内蔵 RAM を 48KB → 40KB にして（`0x28000`〜`0x29FFF` をなくし、`0x2A000`〜 はデータだけ）、空いた 4 ブロックをデータキャッシュにした

### CPU の速さ

3 段のパイプライン（`rtl/cpu.v`）。

- **F**：命令の口に番地を出す。ROM と内蔵 RAM は、偶数番目と奇数番目の 4 バイトを別のメモリにしてあるので、どこから始まる 8 バイトの命令でも 1 クロックで読める。メモリは 2 ポートで、片方を命令の口、もう片方をデータの口が使う
- **E**：解読・レジスタの読み出し・演算・分岐。演算の結果はそのクロックのうちにレジスタへ書くので、すぐ次の命令がそのまま使える。分岐はここで決まり、飛ぶときは先に読んでいた 1 命令を捨てる
- **M**：読み出しの返事を受け取ってレジスタへ書く。その値をすぐ次の命令が使うときだけ 1 クロック待つ

自分を書き換えるコードにも対応する：書き込む番地が、もう読んである命令に重なっていたら読み直す。分岐の予測はしない。

Verilog で測った 1 命令あたりのクロック数（`test/cpi.asm`。テストで上限を見張っている）：

| 命令 | 前（パイプラインなし） | 今 |
|---|---|---|
| 演算・比較・掛け算・飛ばない分岐 | 7 | 1 |
| 飛ぶ分岐・CALL・RET | 7 | 2 |
| 内蔵 RAM の書き込み | 9 | 1 |
| 内蔵 RAM の読み出し | 10 | 1（すぐ次で使うなら 2） |
| M 形式（メモリの値で演算） | 10 | 3 |
| SDRAM の読み出し／書き込み | 14 ／ 11 | 1 ／ 1（データキャッシュ。すぐ次で使う読み出しは 2。外れたときだけライン読み込みに約 24 クロック、汚れていれば書き戻しに約 40 クロック足す） |
| 割り算 | 40 | 34 |
| SDRAM に置いたコード（演算） | 15 | 1.1（命令キャッシュ。外れたときだけライン読み込みに約 20 クロック） |

再帰の fib・ふるい・メモリのコピーを混ぜた 22 万命令のプログラムでは 1,673,616 → 283,507 クロック（5.9 倍。27MHz で 3.6 → 21.4 MIPS）。

### SDRAM

GW2AR-18 のチップの中にある 64Mbit の SDRAM（2M × 32bit、4 バンク × 2048 行 × 256 列）を、`rtl/sdram.v` で CPU と同じ 27MHz で動かす。

- 1 回ごとに行を開き（ACTIVE）、自動プリチャージ付きの READ / WRITE をする。バースト長 1、CAS レイテンシ 2。1 回のアクセスは読み出し 6 クロック・書き込み 4 クロックほど、リフレッシュと重なると 9 クロックくらい（内蔵 RAM は 2 クロック）。命令もデータもキャッシュ（上）を通すので、SDRAM に置いたプログラムも内蔵 RAM とほぼ同じ速さで動く。キャッシュのライン読み込みと書き戻しは 16 語のバースト（自動プリチャージは最後の READ / WRITE だけ）
- リフレッシュは 7.8µs ごと。電源投入後は 200µs 待ち、プリチャージ、リフレッシュ 8 回、モード設定をしてから使えるようになる（その前のアクセスは待たされる）
- SDRAM のクロックは CPU のクロックを反転したもの。こちらが出力を変えてから半周期後に SDRAM が読み取り、読み出しのデータは READ から 2 クロック後に取り込む
- トップのポート名（`O_sdram_clk`・`IO_sdram_dq` など）は Gowin がチップの中の SDRAM につなぐ決まった名前なので、`.cst` にピンは書かない
- `tb/sdram_model.v` は、初期化の手順・tRCD・tRP・tRAS・tRC・tRFC・tWR・リフレッシュの間隔・開いていないバンクへのアクセスを調べ、違反があればエラーにする。わざと壊した制御回路（リフレッシュを 16µs にする、取り込みを 1 クロック遅らせる、書き込みの後の待ちを減らす、初期化のリフレッシュを 1 回にする、DQM を戻し忘れる）は、どれもエラーになることを確かめた

実機で怪しいのは、PLL（`rPLL`）・分周（`CLKDIV`）・シリアライザ（`OSER10`）・差動出力（`ELVDS_OBUF`）の設定と、`.cst` のピン番号、SDRAM のクロックの位相（反転したクロックで足りるか）。HDMI は Sipeed の HDMI 例、microSD（CLK 83・CMD 82・DAT0 84・DAT3 81）は Sipeed の NESTang 例と同じ値にした。実物の SD カードは、モデルより応答が遅かったり、初期化のくせがあったりするので、そこはボードで試すまでわからない。
