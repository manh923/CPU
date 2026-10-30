#ifndef __GFX_H
#define __GFX_H

// グラフィック画面（libc/gfx.c。isa-spec.md の 7.3）：320 × 200 点・256 色（パレット）。
// フレームバッファは SDRAM の 0x017E0000 から 64KB（1 点 1 バイト = パレットの番号、左上から横に並ぶ）。
// gfx_fb はそれをデータキャッシュを通さない番地（0x027E0000）で指すので、書けばすぐ画面に出る。
// 速く描くには、自分のバッファ（キャッシュが効く）に描いてから gfx_present でまとめて写す。
// MyDOS はプログラムが終わるとテキストに戻す
#define GFX_W 320
#define GFX_H 200

#define gfx_fb ((unsigned char *)0x027E0000)

void gfx_mode(int on);                       // 1 = グラフィック（標準のパレットにして 0 で消す）、0 = テキスト
void gfx_palette(int i, int r, int g, int b); // 色 i を (r, g, b)（0〜255）に
void gfx_clear(int c);
void gfx_pset(int x, int y, int c);          // 画面の外は何もしない
int gfx_pget(int x, int y);
void gfx_line(int x0, int y0, int x1, int y1, int c);
void gfx_box(int x, int y, int w, int h, int c);   // 塗りつぶした四角
void gfx_present(const unsigned char *buf);  // 320 × 200 のバッファを画面へ（4 バイトずつ）

#endif
