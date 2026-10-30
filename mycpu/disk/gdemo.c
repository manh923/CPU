// グラフィック画面の見本：マンデルブロ集合を 320 × 200・256 色で描く（整数の固定小数点。浮動小数点は使わない）。
// キーを押すと終わる（MyDOS がテキストの画面に戻す）
#include <conio.h>
#include <gfx.h>
#include <stdio.h>

int main(void) {
  gfx_mode(1);
  for (int i = 1; i < 64; i++) {                // 1〜63：青 → 水色 → 黄 → 赤のなめらかな色
    int t = i * 4, g = 255 - (t * 2 > 255 ? t * 2 - 255 : 255 - t * 2);
    gfx_palette(i, t, g, 255 - t);
  }
  for (int py = 0; py < GFX_H; py++) {
    int ci = (py - GFX_H / 2) * (3 << 12) / GFX_H;           // 虚部（12bit の固定小数点）
    for (int px = 0; px < GFX_W; px++) {
      int cr = (px - GFX_W * 2 / 3) * (3 << 12) / GFX_H;     // 実部
      int zr = 0, zi = 0, n = 0;
      while (n < 64) {
        int rr = zr * zr >> 12, ii = zi * zi >> 12;
        if (rr + ii > (4 << 12))
          break;
        zi = (zr * zi >> 11) + ci;
        zr = rr - ii + cr;
        n++;
      }
      gfx_pset(px, py, n == 64 ? 0 : n);
    }
  }
  gfx_line(0, 0, GFX_W - 1, 0, 15);
  gfx_line(0, GFX_H - 1, GFX_W - 1, GFX_H - 1, 15);
  getch();
  return 0;
}
