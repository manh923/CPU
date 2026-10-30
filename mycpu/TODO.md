# これからやること（メモ）

## ゴール：C コンパイラのセルフホスト

MyDOS の上で C コンパイラを動かし、C のプログラム（コンパイラ自身も）をコンパイルする。これを「いちばん嬉しい瞬間」にする。

決めたこと（2026-10-25）：

| 項目 | 決定 |
|---|---|
| C コンパイラ | chibicc（MIT ライセンス）を改造する。コード生成をこの CPU 向けに書き換える。最初は PC の上で動かす |
| ゴール | セルフホスト（MyDOS の上で chibicc が chibicc をコンパイルできる） |
| プログラムの置き場所 | SDRAM。速くするため CPU に命令キャッシュを付ける（BSRAM の空き 4 ブロック = 8KB） |
| 浮動小数点 | ソフトウェアで対応する（済み。下の 7） |

## 順番（案）

1. ~~命令キャッシュ（Verilog）~~ 済み：SDRAM 上のプログラムも 1 命令 1.26 クロック（前は 12.7）
2. ~~MyDOS：.EXE を SDRAM に読み込めるようにする~~ 済み：`.org 0x1000000` の .EXE は SDRAM に読み込み、スタックも SDRAM の末尾（`disk/big.exe.asm`）
3. ~~chibicc のコード生成をこの CPU 向けに~~ 済み：`cc/`。chibicc のテスト 41 本のうち、x86・pthread のもの以外の 38 本が通る。`long long` は 64bit
4. ~~小さな C ライブラリ~~ 済み（`libc/`）：printf・文字列・malloc・FILE（fopen など。MyDOS に seek の SYSCALL 22 を足した）・conio・errno・limits・stdint・inttypes・assert・setjmp・time。テストは `test/libtest.c`
4.6. ~~AS.EXE（C で書いたアセンブラ）~~ 済み（`disk/as.c`。JS 版と同じバイト列、リンカの代わりも。MyDOS の上で動いた）
4.5. ~~EDIT.EXE~~ 済み（`disk/edit.c`。BIOS に gotoxy・getxy の SYSCALL 11・12、CLS は端末も消す、getc はカーソルの下の文字を壊さない）
5. C で Hello, World → 実機で表示：シミュレータ・Verilog では `disk/primes.c`（`PRIMES.EXE`）が MyDOS で動いた。あとは実機
6. ~~chibicc 自身をこの CPU 向けにコンパイルして、MyDOS の上で動かす（セルフホスト）~~ 済み：カードに CC.EXE・LIBC・ヘッダ・chibicc のソース。
   `BUILD 名前` で C → .EXE（AS -lib LIBC）、`SELFHOST CC CC2` → `SELFHOST CC2 CC3` で CC2.EXE と CC3.EXE が 1 バイトも違わない（シミュレータで確かめた）
7. ~~浮動小数点（ソフトウェア）~~ 済み：float 32bit・double 64bit（long double も 64bit）、IEEE 754。
   四則・比較・変換は `libc/softfloat.c`、printf の %f・%e・%g と strtod は `libc/fltio.c`（正しく丸める）、
   `math.h` は `libc/math.c`。どれも PC の gcc・glibc とビット単位で比べるテストがある（`test/floattest.c`・`fltiotest.c`・`mathtest.c`・`cfloat.c`）
   - 遅い：double の足し算 1 回で約 1500 命令（実機の 21 MIPS で 1 秒に 1.4 万回ほど）。速くするなら softfloat をアセンブリで書く・コンパイラにレジスタ割り当てを入れる

## 実機（Tang Nano 20K、届いたら）

小さいものから順に確かめる：LED の点滅 → UART だけ → CPU ＋ UART → HDMI → SD カード → SDRAM。
書き込みは openFPGALoader（`-b tangnano20k`）か Gowin の Programmer。合成は Gowin EDA。

## 速くする（いちばんの目標。セルフホストが実機で 1 段階 3〜9 分の見込み。hello.c なら 4 秒）

決めたこと（2026-10-26）：やるのは次の 4 つ。順番は 1 → 2 → 3 → 4（ハードの 2 つは実機で速さを測りながら）。
5 段・8 段パイプラインとクロックを上げるのはやらない（27MHz のまま）。

### ソフト
1. ~~コンパイラ（cc/codegen.c）にレジスタ割り当て~~ 済み：変数を callee-saved のレジスタに、葉の関数はフレームなし
2. ~~バイナリを小さくする~~ 済み：AS -lib が LIBC のうち使う関数だけを入れる（区切りのある .EXE）。printf の long long・小数も使うときだけ
   - 残り：softfloat をアセンブリで（double の足し算 1 回が約 1500 命令）

### ハード（CPU・Verilog）
3. **データキャッシュ**：EXE はスタックも SDRAM なので、読み書きのたびに SDRAM を待つ。実機で 2〜3 倍
4. **分岐予測**：今は分岐が成立すると 2 クロック損する（予測なし）。ループの多いコードに効く

## グラフィックと DOOM（いつか）

- グラフィックの画面：**320×200・256 色（パレット）**、フレームバッファは SDRAM（64KB）。表示回路が 1 行ずつバーストで読み、
  3 倍に拡大して 720p の真ん中に（960×600、まわりは枠）。帯域は 1 秒に約 4MB で SDRAM（最大 54MB）に余裕がある。
  テキスト画面と切り替え（isa-spec.md の 7.3。720p・16bit 色は帯域が足りないのでやめた）
- **DOOM を移植する**：解像度・色数が元の DOOM（320×200・256 色）とぴったり同じ。doomgeneric を使えば、
  画面に描く・キーを読む・時間を測る、の数個の関数を書くだけ。DOOM は固定小数点（整数）なので softfloat は要らない。
  必要なメモリは 4MB ほど（SDRAM 8MB で足りる）、WAD（体験版 doom1.wad 約 4MB）は SD カードに。
  遊べる速さにするには、上の「速くする」（レジスタ割り当て・データキャッシュ）が先。キーボードは今の UART でも動くが、PS/2 があると楽
- **2D のアクセラレータ（ブリッタ）を CPU の横に**（3D の GPU は FPGA に入らないのでやらない）：CPU がレジスタに
  「どこからどこへ・幅・高さ」を書くと、回路が SDRAM の上でやる。四角の塗りつぶし・コピー（色 0 を透明に）・線。
  DOOM には縦 1 列を描く回路（`R_DrawColumn`：テクスチャの 1 列を倍率を付けて描く）と横 1 行（`R_DrawSpan`：床・天井）が効く。
  まずグラフィック画面を作って DOOM を CPU だけで動かし、遅いところを測ってから回路にする

## メモリが足りない（セルフホスト）

- MyDOS の上で chibicc の PARSE.C をコンパイルすると、ヒープを 6.07MB 使う（SDRAM のプログラム用は 0x17EFFFF まで。
  式のノードを前半だけ確保して 7.76MB から減らした）。chibicc は確保したものを捨てない作り
- まだ減らせる：Token（72 バイト × 約 2.5 万個 = 1.8MB）、キャストのたびの copy_type、出力のバッファ（realloc で 2 倍ずつ）
- 根本の解決は SDRAM を増やすこと（下の ASIC。Tang Nano 20K は 8MB で固定）

## ASIC にするとき（FPGA で完成してから）

- チップの中：CPU・キャッシュ・ROM・RAM と、昔の PC のサウスブリッジ相当（SD・UART・HDMI・タイマー・PS/2・GPIO）。
  チップの外：メモリ 1 個・SD の差し口・HDMI・USB-C（電源）だけ。マッチ箱くらいの箱に
- SDRAM は 64MB（512Mbit の SDR SDRAM）にする：番地は 0x1000000〜0x4FFFFFF。
  **今のうちに SDRAM の制御回路（rtl/sdram.v）の大きさをパラメータに**（行・列・バンクの bit 数。今は 8MB 用の 21bit の語の番地で固定）。
  BIOS の SDRAM の検査も大きさに合わせる（MyDOS・malloc は SP の手前まで使うのでそのまま広がる）
- DRAM はチップに載せられない（製造プロセスが違う）。8MB の SRAM も大きすぎるので、メモリは外
- 作るときに、オープンソースの道具（OpenLane など）と相乗りの試作サービスの今の状況・値段を調べる。一発勝負なので FPGA で十分試してから
