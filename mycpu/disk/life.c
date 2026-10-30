// LIFE：ライフゲーム（セル・オートマトン）をグラフィック画面（320 × 200）いっぱいに。端は反対側につながる。
//   生きているセルは年齢で色が変わり（白 → 黄 → 橙 → 赤 → 紫 → 青）、死んだセルは少しの間、暗い跡が残る。
//   Enter：動かす・止める  矢印：カーソル（WASD は 8 マス）  スペース：点を置く・消す
//   N：1 世代だけ進める（止めているとき）  R：乱数で埋める  C：全部消す  G：グライダー銃を置く  ESC：終わり
// 速くするため、セルは 1 バイト（0 か 1）で、4 つずつ 32bit の語で計算する：上・今・下の行を語ごとに足して列の和、
// それを 1 バイトずらしたものと足して隣の数（バイトごとに 9 まで。繰り上がらない）。生きるのは (隣の数 | 自分) が 3 のとき。
// 色の更新は、生きているセルのある語だけ 1 つずつ。ない語は跡を 4 つまとめて薄くする
#include <conio.h>
#include <gfx.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W GFX_W
#define H GFX_H
#define WW (W / 4)                      // 1 行の語数
#define RS (WW + 2)                     // 盤の 1 行の語数（両端に、反対側の端の写しを 1 語ずつ）
#define ALIVE 64                        // 65〜127：生きている（年齢 1〜63）
#define TRAIL_LEN 40                    // 1〜40：死んだ跡（40 から毎世代 1 ずつ減って消える）
#define C_CURSOR 255
#define C_TEXT 254

static unsigned cells[2][RS * (H + 2)];  // 1 バイト 1 セル、生きていれば 1（上下・左右の端は反対側の写し）
static unsigned view[WW * H];            // 画面に出すもの（1 バイト 1 点、パレットの番号 = 状態）
static unsigned colsum[RS];
static int cur, gen, running = 1, cx = W / 2, cy = H / 2;

static unsigned char *at(int b, int x, int y) { return (unsigned char *)&cells[b][(y + 1) * RS + 1] + x; }
#define VIEW ((unsigned char *)view)

// 年齢・跡の色
static void set_palette(void) {
  static const int stops[6][3] = {
    {255, 255, 255}, {255, 230, 60}, {255, 130, 20}, {230, 30, 40}, {170, 40, 200}, {50, 80, 255},
  };
  gfx_palette(0, 0, 0, 0);
  for (int a = 1; a <= 63; a++) {        // 年齢：5 区間をなめらかに
    int t = (a - 1) * 5 * 256 / 63, k = t >> 8, f = t & 255;
    if (k > 4) { k = 4; f = 256; }
    const int *p = stops[k], *q = stops[k + 1];
    gfx_palette(ALIVE + a, p[0] + (q[0] - p[0]) * f / 256, p[1] + (q[1] - p[1]) * f / 256, p[2] + (q[2] - p[2]) * f / 256);
  }
  for (int i = 1; i <= TRAIL_LEN; i++)    // 跡：暗い青から黒へ
    gfx_palette(i, 0, i * 30 / TRAIL_LEN, 20 + i * 90 / TRAIL_LEN);
  gfx_palette(C_CURSOR, 80, 255, 80);
  gfx_palette(C_TEXT, 255, 255, 255);
}

static void clear(void) {
  memset(cells[cur], 0, sizeof(cells[cur]));
  memset(view, 0, sizeof(view));
  gen = 0;
}

static void put(int x, int y, int on) {
  x = (x % W + W) % W;
  y = (y % H + H) % H;
  *at(cur, x, y) = on;
  VIEW[y * W + x] = on ? ALIVE + 1 : 0;
}

static void randomize(void) {
  clear();
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++)
      if (rand() % 100 < 22)
        put(x, y, 1);
}

// グライダー銃（左上がカーソル）
static void gun(int x0, int y0) {
  static const char *rows[9] = {
    "........................O...........",
    "......................O.O...........",
    "............OO......OO............OO",
    "...........O...O....OO............OO",
    "OO........O.....O...OO..............",
    "OO........O...O.OO....O.O...........",
    "..........O.....O.......O...........",
    "...........O...O....................",
    "............OO......................",
  };
  for (int y = 0; y < 9; y++)
    for (int x = 0; rows[y][x]; x++)
      if (rows[y][x] == 'O')
        put(x0 + x, y0 + y, 1);
}

// 1 行（いちばん時間のかかるところなので、アセンブリで）。引数は r16 = 今の行（上下の行は ±RS 語）、
// r17 = 次の世代の行、r18 = 色の行（1 語手前から）、r19 = 列の和の置き場（RS 語）。r24〜r27 は退避して使う。
//   列の和：s[i] = 上[i] + 今[i] + 下[i]（バイトごと、3 まで）
//   隣の数 n = (s[i] を左へ 1 バイト ＋ 左隣の語の上のバイト) ＋ s[i] ＋ (右へ 1 バイト ＋ 右隣の語の下のバイト) − 今
//   生きる：(n | 今) が 3 のバイト（^ 0x03030303 して 0 のバイトを探す）
//   色（バイトごと）：生まれた → 65、生き続けた → +1（127 まで）、死んだ → 40、どちらでもない → 0 でなければ −1。
//   生きているセルも色もない語は飛ばす
static void row(unsigned *me, unsigned *out, unsigned *v, unsigned *s) {
  asm(
    "        ADDI32 sp, sp, -16\n"
    "        STORE32_32 r24, sp, 0\n"
    "        STORE32_32 r25, sp, 4\n"
    "        STORE32_32 r26, sp, 8\n"
    "        STORE32_32 r27, sp, 12\n"
    "        ADDR32 r20, r16, r0\n"
    "        ADDR32 r21, r19, r0\n"
    "        ADDI32 r22, r0, 82\n"
    ".col:   LOAD32_32 r23, r20, -328\n"
    "        ADD32 r23, r23, r20, 0\n"
    "        ADD32 r23, r23, r20, 328\n"
    "        STORE32_32 r23, r21, 0\n"
    "        ADDI32 r20, r20, 4\n"
    "        ADDI32 r21, r21, 4\n"
    "        ADDI32 r22, r22, -1\n"
    "        CMPNEI32 p1, r22, 0\n"
    "        BR32 p1, .col\n"
    "        ADDI32 r16, r16, 4\n"
    "        ADDI32 r17, r17, 4\n"
    "        ADDI32 r18, r18, 4\n"
    "        ADDI32 r19, r19, 4\n"
    "        ADDI32 r20, r0, 80\n"
    ".w:     LOAD32_32 r21, r19, 0\n"
    "        LOAD32_32 r22, r19, -4\n"
    "        LOAD32_32 r23, r19, 4\n"
    "        LOAD32_32 r24, r16, 0\n"
    "        SHRI32 r22, r22, 24\n"
    "        SHLI32 r25, r21, 8\n"
    "        ORR32 r22, r22, r25\n"
    "        SHLI32 r23, r23, 24\n"
    "        SHRI32 r25, r21, 8\n"
    "        ORR32 r23, r23, r25\n"
    "        ADDR32 r22, r22, r21\n"
    "        ADDR32 r22, r22, r23\n"
    "        SUBR32 r22, r22, r24\n"
    "        ORR32 r22, r22, r24\n"
    "        XORI32 r22, r22, 0x03030303\n"
    "        ANDI32 r23, r22, 0x7F7F7F7F\n"
    "        ADDI32 r23, r23, 0x7F7F7F7F\n"
    "        ORR32 r23, r23, r22\n"
    "        ORI32 r23, r23, 0x7F7F7F7F\n"
    "        XORI32 r23, r23, -1\n"
    "        SHRI32 r23, r23, 7\n"
    "        STORE32_32 r23, r17, 0\n"
    "        LOAD32_32 r25, r18, 0\n"
    "        ORR32 r21, r24, r23\n"
    "        ORR32 r22, r21, r25\n"
    "        CMPEQI32 p1, r22, 0\n"
    "        BR32 p1, .next\n"
    "        XORI32 r21, r21, -1\n"
    "        ANDI32 r21, r21, 0x01010101\n"
    "        ANDI32 r22, r25, 0x7F7F7F7F\n"
    "        ADDI32 r22, r22, 0x7F7F7F7F\n"
    "        ORR32 r22, r22, r25\n"
    "        SHRI32 r22, r22, 7\n"
    "        ANDR32 r21, r21, r22\n"
    "        SUBR32 r26, r25, r21\n"
    "        XORI32 r21, r25, 0x7F7F7F7F\n"
    "        ANDI32 r22, r21, 0x7F7F7F7F\n"
    "        ADDI32 r22, r22, 0x7F7F7F7F\n"
    "        ORR32 r22, r22, r21\n"
    "        SHRI32 r22, r22, 7\n"
    "        ANDR32 r21, r23, r24\n"
    "        ANDR32 r21, r21, r22\n"
    "        ADDR32 r26, r26, r21\n"
    "        XORI32 r21, r24, -1\n"
    "        ANDR32 r21, r21, r23\n"
    "        XORI32 r22, r23, -1\n"
    "        ANDR32 r22, r22, r24\n"
    "        ORR32 r27, r21, r22\n"
    "        MULI32 r27, r27, 255\n"
    "        XORI32 r27, r27, -1\n"
    "        ANDR32 r26, r26, r27\n"
    "        MULI32 r21, r21, 65\n"
    "        ORR32 r26, r26, r21\n"
    "        MULI32 r22, r22, 40\n"
    "        ORR32 r26, r26, r22\n"
    "        STORE32_32 r26, r18, 0\n"
    ".next:  ADDI32 r16, r16, 4\n"
    "        ADDI32 r17, r17, 4\n"
    "        ADDI32 r18, r18, 4\n"
    "        ADDI32 r19, r19, 4\n"
    "        ADDI32 r20, r20, -1\n"
    "        CMPNEI32 p1, r20, 0\n"
    "        BR32 p1, .w\n"
    "        LOAD32_32 r24, sp, 0\n"
    "        LOAD32_32 r25, sp, 4\n"
    "        LOAD32_32 r26, sp, 8\n"
    "        LOAD32_32 r27, sp, 12\n"
    "        ADDI32 sp, sp, 16\n"
  );
}

// 1 世代進める
static void step(void) {
  unsigned *a = cells[cur], *b = cells[cur ^ 1];
  // 端：左右は反対側の端の語（左の写しは上のバイト、右の写しは下のバイトだけを使う）、上下は反対側の行
  for (int y = 1; y <= H; y++) {
    a[y * RS] = a[y * RS + WW];
    a[y * RS + WW + 1] = a[y * RS + 1];
  }
  memcpy(a, a + H * RS, RS * 4);
  memcpy(a + (H + 1) * RS, a + RS, RS * 4);

  for (int y = 1; y <= H; y++)
    row(a + y * RS, b + y * RS, view + (y - 1) * WW - 1, colsum);
  cur ^= 1;
  gen++;
}

// 3 × 5 の数字（左上に世代を出す）
static const unsigned short digits[10] = {
  075557, 026222, 071747, 071717, 055711, 074717, 074757, 071111, 075757, 075717,
};
static unsigned char save[64 * 7];
static void overlay(int on) {
  // 左上 64 × 7 を一時的に書き換え（on = 0 で元に戻す）
  for (int y = 0; y < 7; y++)
    for (int x = 0; x < 64; x++) {
      unsigned char *p = &VIEW[y * W + x];
      if (on) { save[y * 64 + x] = *p; *p = 0; }
      else *p = save[y * 64 + x];
    }
  if (!on)
    return;
  char s[12];
  int len = 0, n = gen;
  do { s[len++] = n % 10; n /= 10; } while (n);
  for (int i = len - 1, x = 1; i >= 0; i--, x += 4)
    for (int r = 0; r < 5; r++)
      for (int k = 0; k < 3; k++)
        if (digits[(int)s[i]] >> ((4 - r) * 3 + (2 - k)) & 1)
          VIEW[(1 + r) * W + x + k] = C_TEXT;
  if (!running)                         // 止めている印（2 本の棒）
    for (int r = 0; r < 5; r++) {
      VIEW[(1 + r) * W + 56] = C_TEXT;
      VIEW[(1 + r) * W + 59] = C_TEXT;
    }
}

int main(void) {
  gfx_mode(1);
  set_palette();
  randomize();
  clock_t next = clock();
  for (;;) {
    while (kbhit()) {
      int k = getch();
      switch (k) {
      case KEY_ESC: return 0;
      case '\r': case '\n': running = !running; break;
      case KEY_LEFT: cx--; break;
      case KEY_RIGHT: cx++; break;
      case KEY_UP: cy--; break;
      case KEY_DOWN: cy++; break;
      case 'a': case 'A': cx -= 8; break;
      case 'd': case 'D': cx += 8; break;
      case 'w': case 'W': cy -= 8; break;
      case 's': case 'S': cy += 8; break;
      case ' ': put(cx, cy, !*at(cur, cx, cy)); break;
      case 'n': case 'N': if (!running) step(); break;
      case 'r': case 'R': randomize(); break;
      case 'c': case 'C': clear(); break;
      case 'g': case 'G': gun(cx, cy); break;
      }
      cx = (cx % W + W) % W;
      cy = (cy % H + H) % H;
    }
    if (running)
      step();
    // カーソル（止めているときだけ）と世代を重ねて、画面へ写す
    int under = VIEW[cy * W + cx];
    if (!running)
      VIEW[cy * W + cx] = C_CURSOR;
    overlay(1);
    gfx_present(VIEW);
    overlay(0);
    VIEW[cy * W + cx] = under;
    // 1 秒に 30 世代まで
    next += CLOCKS_PER_SEC / 30;
    while (clock() < next)
      ;
    if (clock() > next + CLOCKS_PER_SEC)
      next = clock();
  }
}
