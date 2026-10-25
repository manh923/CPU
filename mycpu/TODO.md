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
6. chibicc 自身をこの CPU 向けにコンパイルして、MyDOS の上で動かす（セルフホスト）
7. ~~浮動小数点（ソフトウェア）~~ 済み：float 32bit・double 64bit（long double も 64bit）、IEEE 754。
   四則・比較・変換は `libc/softfloat.c`、printf の %f・%e・%g と strtod は `libc/fltio.c`（正しく丸める）、
   `math.h` は `libc/math.c`。どれも PC の gcc・glibc とビット単位で比べるテストがある（`test/floattest.c`・`fltiotest.c`・`mathtest.c`・`cfloat.c`）
   - 遅い：double の足し算 1 回で約 1500 命令（実機の 21 MIPS で 1 秒に 1.4 万回ほど）。速くするなら softfloat をアセンブリで書く・コンパイラにレジスタ割り当てを入れる

## 実機（Tang Nano 20K、届いたら）

小さいものから順に確かめる：LED の点滅 → UART だけ → CPU ＋ UART → HDMI → SD カード → SDRAM。
書き込みは openFPGALoader（`-b tangnano20k`）か Gowin の Programmer。合成は Gowin EDA。

## そのほか（急がない）

- MyDOS のサブディレクトリ：今はルートだけ。パス（`C:\INCLUDE\STDIO.H`）・`MKDIR`・`RMDIR`・`CD`・`DIR` の中身、
  プログラムを今のディレクトリ → ルートの順に探す。mkdisk もサブディレクトリに。そうしたらヘッダを `INCLUDE\`、
  chibicc のソースを `SRC\CC\` に分ける（今は全部ルートに平らに置き、libc の fopen がディレクトリを捨てて 8.3 にしている）

- 読み出しの値をすぐ次の命令に回す（今は 1 クロック待つ）
- クロックを上げる（54MHz など）。実機で確かめてから
- 8 段パイプライン（ロマン枠）
