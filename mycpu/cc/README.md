# cc — この CPU 向けの C コンパイラ（chibicc の改造版）

[chibicc](https://github.com/rui314/chibicc)（Rui Ueyama、MIT ライセンス。`LICENSE`、元の説明は `README.chibicc.md`）の 90d1f7f を、この CPU（MyCPU、32bit）向けに改造したもの。取り込んだままの版はコミット 2d5e89b にあるので、差分で何を変えたかを追える。

PC の上では `node tools/cc.js prog.c -o PROG.EXE` で使う（`tools/cc.js` が `make` でこのコンパイラを作り、C ライブラリ `libc/` と一緒に `.EXE` にする）。`disk/` に置いた `NAME.c` は、mkdisk・シミュレータ・ブラウザ版の素材を作るときに `NAME.EXE` にもなる。

## 変えたところ

- **`codegen.c`**：まるごと書き直した。x86-64 ではなく、この CPU のアセンブリ（`lib/assembler.js` の書き方）を出す。作りは元と同じスタックマシン（値は r16、途中の値はスタック）
  - 呼び出し規約は `isa-spec.md` の 8 章：引数は r16〜r21、戻り値は r16。構造体と `long long` の引数はスタック。構造体を返すときは、呼ぶ側のバッファの番地を隠れた最初の引数で渡す
  - `long long` はレジスタ 2 つ（r16 = 下位、r17 = 上位）。割り算・余りは `libc/divdi3.c` を呼ぶ
  - 可変長引数：レジスタで来た引数を 8 バイトずつ並べて置き、`va_list` はそこを指す（`include/stdarg.h`）
  - 名前：C の大域の名前は `_名前`、static と内部のラベルは `L<ファイルの番号>…`（ファイルのパスのハッシュ）。日本語などの識別子は `.16 進` に直す
  - データとコードは `; @data`・`; @text` の行で区切り、初期値なしの大域変数は `; @common` で出す。`tools/cc.js` がリンカの代わりに並べ直す
- **`type.c`・`parse.c`・`tokenize.c`**：ILP32 にした。`long` とポインタは 4 バイト、`long long` は 8 バイト（`ty_llong` を足した）。定数の型の決め方も合わせた。構造体を返す関数には大きさによらず隠れた引数を付ける。定数式で 0 で割ったらエラーにする
- **`preprocess.c`**：`__x86_64__`・`__LP64__` などをやめ、`__MYCPU__`・`__ILP32__` を定義。大きさのマクロも ILP32 に
- **`main.c`**：標準ヘッダは `cc/include`（chibicc 付属）と `libc/include` だけを探す
- **`test/`**：chibicc のテスト。long とポインタの大きさなど、ILP32 で変わる期待値だけ直した（直したファイルは先頭に「MyCPU：」のコメント）。`common.c` は元の `common` から float・double の関数を外したもの

## まだできないこと

- `float`・`double`・`long double`（使うとエラー。ソフトウェアで対応する予定。`TODO.md`）
- インラインアセンブリ（x86 のものは当然動かない）、スレッド
- `long long` のビットフィールドと、8 バイトのアトミック操作

## テスト

```sh
node test/cctest.js            # chibicc のテストを全部（名前を並べるとそれだけ）
```

MyDOS は使わず、ROM に小さなカーネル（SYSCALL の終了・1 文字・文字列だけ）を置いて、JS のシミュレータで動かす。`test/run.js` にも入っている。今は 41 本のうち 29 本が通る（残りは float・double を使う 9 本と、x86 のアセンブリ・pthread を使う 3 本）。
