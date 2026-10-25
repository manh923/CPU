# MyCPU

`isa-spec.md`（命令セット仕様書 v0.7）と `opcodes.csv` から作った、アセンブラ・シミュレータ・Verilog（32bit 版、Tang Nano 20K 向け）。

| 場所 | 中身 |
|---|---|
| `opcodes.csv` | 全命令の表。ほかはすべてここから作る（`tools/gen.js`） |
| `asm/asm.js` | アセンブラ（コマンドライン） |
| `sim/sim.js` | シミュレータ（コマンドライン。キー入力・画面表示つき） |
| `web/index.html` | シミュレータ（ブラウザ。ファイルを直接開くだけで動く） |
| `lib/` | アセンブラ・CPU・表示の本体（Node とブラウザで共通） |
| `examples/` | 例題（`mydos.asm` は BIOS ＋ブートローダー＋ MyDOS） |
| `disk/` | SD カードの中身のもと（`tools/mkdisk.js` で作る） |
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
node sim/sim.js examples/mydos.asm --sd disk/ --screen   # BIOS → SD カードの MyDOS。HELP でコマンド一覧
node sim/sim.js examples/console.asm --screen   # 画面（VRAM）を端末に表示。キー入力はその場で届く。Ctrl-] で終了
node sim/sim.js examples/selftest64.asm --cpu 64
node sim/sim.js examples/colors.asm --png screen.png   # 止まったときの画面を PNG に
node test/run.js                            # テスト一式
```

`sim.js` のオプション：`--cpu 32|64`、`--trace`（1 命令ずつ表示）、`--max N`、`--input 文字列`（UART 受信に入れておく）、`--rx-file ファイル`（同じくファイルの中身）、`--sd フォルダ|.img`（SD カードを挿す）、`--screen`、`--png`／`--ppm`、`--regs ファイル|-`、`--realtime`（タイマーを実時間で進める）。

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

## MyDOS（`examples/mydos.asm`）

1. **BIOS**（ROM）：見出し、メモリテスト（内蔵 RAM を 1KB ずつ書いて読み戻す）、SD カードの初期化
2. 1 秒だけ **U キー**を待つ。U なら UART から起動、ほかのキーか時間切れなら次へ
3. **ブートローダー**：ROM の中の MyDOS を RAM の `0x20000` に写して飛ぶ
4. **MyDOS**：SD カードの FAT（FAT16 / FAT32）を読み、`AUTOEXEC.BAT` があれば実行して `C:\>` を出す

ドライブ C: は microSD カード（SPI モード、**読み出しだけ**）。PC で FAT にフォーマットしたカードのルートにファイルを置けば、そのまま見える。

- 組み込みのコマンド：`DIR`、`TYPE`、`VOL`、`VER`、`CLS`、`ECHO`、`MEM`、`TIME`、`COLOR 1F`、`LED 2A`、`HELP`、`REBOOT`、`SHUTDOWN`
- それ以外は SD カードから探して実行する：名前だけなら `.EXE` → `.COM` → `.BAT` の順
  - `.EXE`：先頭 16 バイトがヘッダ（`'MZ'`、ヘッダの大きさ 2 バイト、読み込む番地・開始番地・本体の大きさ 各 4 バイト）。`0x23000` に読み込んで実行
  - `.COM`：ヘッダなし。`0x23000` に置いてそのまま実行
  - `.BAT`：1 行ずつコマンドとして実行（`@` で始まる行は表示しない。別の `.BAT` を実行するとそちらへ移る）
  - プログラムは r16 に引数の文字列を受け取り、`RET32` で `C:\>` に戻る。大きさは 16KB（`0x23000`〜`0x26FFF`）まで
- パーティション表あり（普通の SD カード）・なし（`mkfs.fat` でそのまま作ったもの）のどちらも読める。長いファイル名の項目は飛ばし、8.3 の名前で扱う。サブディレクトリは `DIR` に `<DIR>` と出るだけ（中には入れない）
- 未対応：書き込み（`COPY`・`DEL` など）、サブディレクトリの中、FAT12、1 セクタ 512 バイト以外

### SD カードの中身を作る

`disk/` に入れる中身がある（`README.TXT`、`AUTOEXEC.BAT`、`DEMO.BAT`、`HELLO.EXE`、`FIB.EXE`、`MANDEL.EXE`、`KITT.COM` のもと）。`NAME.exe.asm` は `NAME.EXE`、`NAME.com.asm` は `NAME.COM` にアセンブルされる（`.org 0x23000` で書く）。

```sh
node tools/mkdisk.js --files sdcard/           # ファイルを作る → FAT でフォーマットした SD カードに PC から写す
node tools/mkdisk.js -o disk.img [--fat32]     # ディスクイメージを作る（シミュレータ用）
node sim/sim.js examples/mydos.asm --sd disk/ --screen    # フォルダを渡すと、その場でイメージを作って挿す
node sim/sim.js examples/mydos.asm --sd disk.img          # .img も挿せる
```

ブラウザ版は、上の「SD：」から disk/ の中身（FAT16 / FAT32）、なし、手元の `.img` を選べる。

### BIOS の入口

プログラムからは、画面や入力・SD カードを BIOS の入口（ROM の決まった番地）を `CALL32` して使う。色は BIOS の変数 `0x27008`（今の色）を直接書き換えてよい（`disk/mandel.exe.asm`）。

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

### UART から起動

起動中に U を押すと、`'MC'`＋長さ（4 バイト）＋本体 を受け取って `0x20000` に置き、そこへ飛ぶ。プログラムは `.org 0x20000` で書く（`examples/uartboot/hello_uart.asm`）。

```sh
node tools/mkboot.js examples/uartboot/hello_uart.asm -o hello.boot
node sim/sim.js examples/mydos.asm --input u --rx-file hello.boot   # シミュレータで試す
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
- SDRAM：シミュレータにはある（8MB）。Verilog にはまだない（つながっていない番地として止まる）

## FPGA（Tang Nano 20K）

32bit 版 CPU、ROM 32KB・内蔵 RAM 32KB・VRAM 16KB（BSRAM）、UART、タイマー、LED、microSD（SPI）、720p のテキスト画面（HDMI 端子から DVI で出す）。CPU は 27MHz で、1 命令あたり 8 クロック前後（約 3.4MIPS。パイプラインなし）。

Gowin EDA での手順：

1. 新しいプロジェクト。デバイスは `GW2AR-LV18QN88C8/I7`
2. 追加するファイル：`rtl/cpu.v rtl/soc.v rtl/uart.v rtl/video.v rtl/tmds.v rtl/gowin/top_tangnano20k.v rtl/gowin/tangnano20k.cst`
3. インクルードのパスに `rtl` を追加（`opcodes.vh` のため）。トップモジュールは `top_tangnano20k`
4. ROM の中身：`node asm/asm.js examples/mydos.asm -o rom` で `rom.hex` を作る。`rom.hex` と `font/font8x16.hex` を、合成ツールが `$readmemh` で見つけられる場所（プロジェクトのフォルダ）に置く
5. 合成・配置配線して書き込む。PC 側は 115200bps の端末ソフトでつなぐ
6. SD カード：PC で FAT32（2GB 以下なら FAT16 も可）にフォーマットし、`node tools/mkdisk.js --files sdcard/` で作ったファイルをルートに写して挿す

**まだ実機で確かめていない。** ここ（クラウドの環境）では Gowin のツールを動かせないので、確かめたのは Icarus Verilog でのシミュレーションまで：

- CPU：例題をシミュレータと同時に動かし、UART の出力と止まったときのレジスタが全部一致
- SD カード：SPI の回路を、SD カード（SPI モード）のモデル（`tb/sd_model.v`）につないで MyDOS を起動。FAT16 のイメージから `AUTOEXEC.BAT`・`HELLO.EXE`・`TYPE`・`DIR` まで、シミュレータと一致
- FAT：`mkfs.fat`・`mtools` で作ったイメージ（FAT16・FAT32、パーティション表なし、長い名前、サブディレクトリ）も読め、空き容量も `mdir` と一致
- 表示回路：1 フレーム（1280×720）を取り込み、シミュレータの絵と 1 ドットまで一致
- TMDS 符号器：符号化したものを元に戻せること、直流の偏りが小さいこと
- トップ：Gowin 部品を代わりのモジュールにしてコンパイルが通ること

実機で怪しいのは、PLL（`rPLL`）・分周（`CLKDIV`）・シリアライザ（`OSER10`）・差動出力（`ELVDS_OBUF`）の設定と、`.cst` のピン番号。HDMI は Sipeed の HDMI 例、microSD（CLK 83・CMD 82・DAT0 84・DAT3 81）は Sipeed の NESTang 例と同じ値にした。実物の SD カードは、モデルより応答が遅かったり、初期化のくせがあったりするので、そこはボードで試すまでわからない。
