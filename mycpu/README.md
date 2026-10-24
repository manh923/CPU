# MyCPU

`isa-spec.md`（命令セット仕様書 v0.5）と `opcodes.csv` から作った、アセンブラ・シミュレータ・Verilog（32bit 版、Tang Nano 20K 向け）。

| 場所 | 中身 |
|---|---|
| `opcodes.csv` | 全命令の表。ほかはすべてここから作る（`tools/gen.js`） |
| `asm/asm.js` | アセンブラ（コマンドライン） |
| `sim/sim.js` | シミュレータ（コマンドライン。キー入力・画面表示つき） |
| `web/index.html` | シミュレータ（ブラウザ。ファイルを直接開くだけで動く） |
| `lib/` | アセンブラ・CPU・表示の本体（Node とブラウザで共通） |
| `examples/` | 例題 |
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
node sim/sim.js examples/console.asm --screen   # 画面（VRAM）を端末に表示。キー入力はその場で届く。Ctrl-] で終了
node sim/sim.js examples/selftest64.asm --cpu 64
node sim/sim.js examples/colors.asm --png screen.png   # 止まったときの画面を PNG に
node test/run.js                            # テスト一式
```

`sim.js` のオプション：`--cpu 32|64`、`--trace`（1 命令ずつ表示）、`--max N`、`--input 文字列`（UART 受信に入れておく）、`--screen`、`--png`／`--ppm`、`--regs ファイル|-`、`--realtime`（タイマーを実時間で進める）。

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
- 疑似命令：`.org .align .space .byte .half .word .dword .ascii .asciz .equ`
- 命令は自動で 4 バイト境界にそろう。幅の合わないレジスタ・予備レジスタ・PC への書き込みはエラー

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

- 外部割り込み：0 = UART 受信データあり、1 = タイマー（どちらもレベル。原因がなくなるまで続く）
- UART は 115200bps・8N1。送信・受信とも 16 バイトの FIFO
- シミュレータのタイマーは、既定では 1 命令 = 1µs として進む（毎回同じ結果になるように）。`--realtime` とブラウザ版は実時間
- STATUS で実装している bit は 0〜3 と 8〜15。ほかは 0 を読む
- 「HLT にする」とされている不正命令は、どちらも止まって理由を出す（Verilog は LED5・LED4 に出す）。つながっていない番地や ROM への書き込みも止まる
- 1bit レジスタをアドレスに使ったときも止まる（v0.5 の 3.3 では決まっていない）
- テキスト VRAM：1 行 160 文字（320 バイト）、色は CGA/VGA の標準 16 色
- SDRAM：シミュレータにはある（8MB）。Verilog にはまだない（つながっていない番地として止まる）

## 仕様の穴（v0.5 で見つかったもの）

- **64bit CPU で 32bit 命令から割り込みを見分けられない**。CAUSE の「最上位 bit = 外部割り込み」は 64bit CPU では bit63 になり、32bit 命令からは下位 32bit しか読めない。32bit 用に書いた例外ハンドラは、64bit CPU 上では「割り込み 1」と「整列違反（コード 1）」を区別できない（`examples/trap.asm` を `--cpu 64` で動かすと再現する）。案：割り込みの印を CPU の bit 数によらず bit31 に置く。

## FPGA（Tang Nano 20K）

32bit 版 CPU、ROM 16KB・内蔵 RAM 32KB・VRAM 16KB（BSRAM）、UART、タイマー、LED、720p のテキスト画面（HDMI 端子から DVI で出す）。CPU は 27MHz で、1 命令あたり 8 クロック前後（約 3.4MIPS。パイプラインなし）。

Gowin EDA での手順：

1. 新しいプロジェクト。デバイスは `GW2AR-LV18QN88C8/I7`
2. 追加するファイル：`rtl/cpu.v rtl/soc.v rtl/uart.v rtl/video.v rtl/tmds.v rtl/gowin/top_tangnano20k.v rtl/gowin/tangnano20k.cst`
3. インクルードのパスに `rtl` を追加（`opcodes.vh` のため）。トップモジュールは `top_tangnano20k`
4. ROM の中身：`node asm/asm.js examples/console.asm -o rom` で `rom.hex` を作る。`rom.hex` と `font/font8x16.hex` を、合成ツールが `$readmemh` で見つけられる場所（プロジェクトのフォルダ）に置く
5. 合成・配置配線して書き込む。PC 側は 115200bps の端末ソフトでつなぐ

**まだ実機で確かめていない。** ここ（クラウドの環境）では Gowin のツールを動かせないので、確かめたのは Icarus Verilog でのシミュレーションまで：

- CPU：例題をシミュレータと同時に動かし、UART の出力と止まったときのレジスタが全部一致
- 表示回路：1 フレーム（1280×720）を取り込み、シミュレータの絵と 1 ドットまで一致
- TMDS 符号器：符号化したものを元に戻せること、直流の偏りが小さいこと
- トップ：Gowin 部品を代わりのモジュールにしてコンパイルが通ること

実機で怪しいのは、PLL（`rPLL`）・分周（`CLKDIV`）・シリアライザ（`OSER10`）・差動出力（`ELVDS_OBUF`）の設定と、`.cst` のピン番号。どれも Sipeed の HDMI 例と同じ値にしたつもり。
