// グラフィック画面（include/gfx.h）。入出力レジスタ（lib/isa.js の IO）を直接書く
#include <gfx.h>
#include <string.h>

#define IO_VIDEO_MODE (*(volatile unsigned *)0x00010040)
#define IO_FB_BASE    (*(volatile unsigned *)0x00010044)
#define IO_PAL_INDEX  (*(volatile unsigned *)0x00010048)
#define IO_PAL_DATA   (*(volatile unsigned *)0x0001004C)

void gfx_palette(int i, int r, int g, int b) {
  IO_PAL_INDEX = i & 255;
  IO_PAL_DATA = (r & 255) << 16 | (g & 255) << 8 | (b & 255);
}

// 標準のパレット：0〜15 はテキスト画面と同じ 16 色、16〜231 は 6 × 6 × 6 の色の立方体、232〜255 は灰色 24 段
static void std_palette(void) {
  static const unsigned c16[16] = {
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
  };
  IO_PAL_INDEX = 0;                     // PAL_DATA に書くたびに番号が 1 進む
  for (int i = 0; i < 16; i++)
    IO_PAL_DATA = c16[i];
  for (int i = 0; i < 216; i++) {
    int r = i / 36, g = i / 6 % 6, b = i % 6;
    IO_PAL_DATA = (r ? r * 40 + 55 : 0) << 16 | (g ? g * 40 + 55 : 0) << 8 | (b ? b * 40 + 55 : 0);
  }
  for (int i = 0; i < 24; i++) {
    int v = i * 10 + 8;
    IO_PAL_DATA = v << 16 | v << 8 | v;
  }
}

void gfx_mode(int on) {
  if (on) {
    IO_FB_BASE = 0x017E0000;
    std_palette();
    gfx_clear(0);
  }
  IO_VIDEO_MODE = on ? 1 : 0;
}

void gfx_clear(int c) {
  unsigned v = (c & 255) * 0x01010101u, *p = (unsigned *)gfx_fb;
  for (int i = 0; i < GFX_W * GFX_H / 4; i++)
    p[i] = v;
}

void gfx_pset(int x, int y, int c) {
  if ((unsigned)x < GFX_W && (unsigned)y < GFX_H)
    gfx_fb[y * GFX_W + x] = c;
}

int gfx_pget(int x, int y) {
  if ((unsigned)x < GFX_W && (unsigned)y < GFX_H)
    return gfx_fb[y * GFX_W + x];
  return 0;
}

void gfx_line(int x0, int y0, int x1, int y1, int c) {
  int dx = x1 > x0 ? x1 - x0 : x0 - x1, sx = x0 < x1 ? 1 : -1;
  int dy = y1 > y0 ? y0 - y1 : y1 - y0, sy = y0 < y1 ? 1 : -1;
  int err = dx + dy;
  for (;;) {
    gfx_pset(x0, y0, c);
    if (x0 == x1 && y0 == y1)
      break;
    int e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x0 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y0 += sy;
    }
  }
}

void gfx_box(int x, int y, int w, int h, int c) {
  for (int j = y; j < y + h; j++)
    for (int i = x; i < x + w; i++)
      gfx_pset(i, j, c);
}

void gfx_present(const unsigned char *buf) {
  memcpy(gfx_fb, buf, GFX_W * GFX_H);   // libc/string.s：4 バイトずつ、16 バイトごとにまとめて
}
