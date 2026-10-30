// BLOCKS：グラフィック画面（320 × 200・256 色）のブロック崩し。
//   ← → か A D でパドルを動かし、スペースで玉を出す。ESC で終わり。
//   キーを押すまでは、パドルが勝手に玉を追う（見せるだけのモード）。
//   ブロックは段ごとに色が違い、灰色のブロックは 2 回当てると壊れる。全部壊すと次の面（並びが変わり、玉が速くなる）。
// 描くのは自分のバッファ（キャッシュが効く）で、1 フレームの最後に gfx_present でまとめて画面へ写す
#include <conio.h>
#include <gfx.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define COLS 13
#define ROWS 7
#define BW 22                           // ブロックの大きさ（すき間 2 を含めて 24 × 10）
#define BH 8
#define TOP 24
#define PW 40                           // パドル
#define PH 5
#define PY 186
#define FP 8                            // 玉の位置・速さは 8bit の固定小数点

static unsigned char buf[GFX_W * GFX_H];
static unsigned char brick[ROWS][COLS];   // 0 = なし、1 = 1 回、2 = 2 回（灰色）
static int left_bricks, level = 1, score, lives = 3, auto_play = 1;
static int px = GFX_W / 2 - PW / 2;      // パドルの左
static int bx, by, vx, vy, stuck = 1;    // 玉（固定小数点）。stuck ならパドルに乗っている
static int aim;                          // 見せるモードで、パドルのどこに当てるか（−14〜14）

// ---- 描く ----
static void box(int x, int y, int w, int h, int c) {
  for (int j = y < 0 ? 0 : y; j < y + h && j < GFX_H; j++) {
    int x0 = x < 0 ? 0 : x, x1 = x + w > GFX_W ? GFX_W : x + w;
    if (x1 > x0)
      memset(buf + j * GFX_W + x0, c, x1 - x0);
  }
}

// 3 × 5 の数字
static const unsigned short digits[10] = {
  075557, 026222, 071747, 071717, 055711, 074717, 074757, 071111, 075757, 075717,
};
static void number(int x, int y, int n, int c) {
  char s[12];
  int len = 0;
  do {
    s[len++] = n % 10;
    n /= 10;
  } while (n);
  for (int i = len - 1; i >= 0; i--, x += 4)
    for (int r = 0; r < 5; r++)
      for (int k = 0; k < 3; k++)
        if (digits[(int)s[i]] >> ((4 - r) * 3 + (2 - k)) & 1)
          buf[(y + r) * GFX_W + x + k] = c;
}

// 段の色（標準のパレット：16〜231 は 6 × 6 × 6 の色）
static int row_color(int r) {
  static const int rgb[ROWS][3] = { {5, 1, 1}, {5, 3, 0}, {5, 5, 1}, {1, 5, 1}, {0, 4, 5}, {2, 2, 5}, {4, 1, 5} };
  return 16 + rgb[r][0] * 36 + rgb[r][1] * 6 + rgb[r][2];
}

static void draw(void) {
  memset(buf, 0, sizeof(buf));
  // 枠
  box(0, 12, GFX_W, 2, 244);
  box(0, 12, 2, GFX_H - 12, 244);
  box(GFX_W - 2, 12, 2, GFX_H - 12, 244);
  // 上の欄：点・残り・面
  number(4, 3, score, 15);
  for (int i = 0; i < lives; i++)
    box(150 + i * 8, 4, 6, 3, 14);
  number(GFX_W - 20, 3, level, 11);
  // ブロック（上と左に明るい線、右と下に暗い線を付けて立体に）
  for (int r = 0; r < ROWS; r++)
    for (int c = 0; c < COLS; c++) {
      if (!brick[r][c])
        continue;
      int x = 4 + c * (BW + 2), y = TOP + r * (BH + 2);
      int col = brick[r][c] == 2 ? 248 : row_color(r);
      box(x, y, BW, BH, col);
      box(x, y, BW, 1, 15);
      box(x, y, 1, BH, 15);
      box(x, y + BH - 1, BW, 1, 8);
      box(x + BW - 1, y, 1, BH, 8);
    }
  // パドルと玉
  box(px, PY, PW, PH, 11);
  box(px + 2, PY, PW - 4, 1, 15);
  box(bx >> FP, by >> FP, 3, 3, 15);
}

// ---- 動き ----
static void new_level(void) {
  left_bricks = 0;
  for (int r = 0; r < ROWS; r++)
    for (int c = 0; c < COLS; c++) {
      // 面ごとに並びを変える：1 面は全部、2 面はひし形、3 面は市松、あとは繰り返し
      int on = 1, d = abs(c - COLS / 2) + abs(r - ROWS / 2);
      if (level % 3 == 2)
        on = d <= 6;
      else if (level % 3 == 0)
        on = (r + c) % 2 == 0;
      brick[r][c] = on ? (r == 1 || (level > 1 && r == 4) ? 2 : 1) : 0;
      left_bricks += on;
    }
  stuck = 1;
}

static void serve(void) {
  bx = (px + PW / 2 - 1) << FP;
  by = (PY - 4) << FP;
  int speed = 2 * 256 + level * 48;
  vx = speed / 2;
  vy = -speed;
  stuck = 0;
}

static void bounce_paddle(void) {
  // 当たった場所で角度を変える（端ほど横に）
  int hit = (bx >> FP) + 1 - (px + PW / 2);   // −20〜20
  int speed = 2 * 256 + level * 48;
  vx = hit * speed / 16;
  if (vx == 0)                          // 真上には返さない
    vx = rand() & 1 ? speed / 8 : -speed / 8;
  vy = -speed;
  by = (PY - 3) << FP;
  aim = rand() % 29 - 14;
}

static void hit_bricks(void) {
  int x = (bx >> FP) + 1, y = (by >> FP) + 1;
  int c = (x - 4) / (BW + 2), r = (y - TOP) / (BH + 2);
  if (y < TOP || r < 0 || r >= ROWS || c < 0 || c >= COLS || !brick[r][c])
    return;
  // どちらの面に当たったか：ブロックの中の位置で決める
  int bx0 = 4 + c * (BW + 2), by0 = TOP + r * (BH + 2);
  int dx = x - bx0 < BW / 2 ? x - bx0 : bx0 + BW - x;
  int dy = y - by0 < BH / 2 ? y - by0 : by0 + BH - y;
  if (dx < dy)
    vx = -vx;
  else
    vy = -vy;
  if (--brick[r][c] == 0) {
    left_bricks--;
    score += 10 * (ROWS - r);
  } else
    score += 5;
}

static void step(void) {
  if (stuck) {
    bx = (px + PW / 2 - 1) << FP;
    by = (PY - 4) << FP;
    return;
  }
  bx += vx;
  by += vy;
  if (bx < 2 << FP) { bx = 2 << FP; vx = -vx; }
  if (bx > (GFX_W - 5) << FP) { bx = (GFX_W - 5) << FP; vx = -vx; }
  if (by < 14 << FP) { by = 14 << FP; vy = -vy; }
  int x = bx >> FP, y = by >> FP;
  if (vy > 0 && y + 3 >= PY && y + 3 <= PY + PH && x + 3 > px && x < px + PW)
    bounce_paddle();
  hit_bricks();
  if (y > GFX_H) {                      // 落とした
    lives--;
    stuck = 1;
  }
}

int main(void) {
  gfx_mode(1);
  new_level();
  clock_t next = clock();
  for (;;) {
    // キー：← → A D でパドル、スペースで玉を出す、ESC で終わり。押したら見せるモードは終わり
    while (kbhit()) {
      int k = getch();
      if (k == KEY_ESC)
        return 0;
      auto_play = 0;
      if (k == KEY_LEFT || k == 'a' || k == 'A')
        px -= 12;
      if (k == KEY_RIGHT || k == 'd' || k == 'D')
        px += 12;
      if (k == ' ' && stuck)
        serve();
    }
    if (auto_play) {                    // 玉を追う（少し遅れて）
      int want = (bx >> FP) - PW / 2 + 1 - aim;
      px += want > px + 3 ? 4 : want < px - 3 ? -4 : want - px;
      if (stuck)
        serve();
    }
    if (px < 2)
      px = 2;
    if (px > GFX_W - 2 - PW)
      px = GFX_W - 2 - PW;
    step();
    if (left_bricks == 0) {
      level++;
      new_level();
    }
    if (lives < 0) {                    // おしまい：初めから
      lives = 3;
      score = 0;
      level = 1;
      new_level();
    }
    draw();
    gfx_present(buf);
    // 1 秒に 60 回まで
    next += CLOCKS_PER_SEC / 60;
    while (clock() < next)
      ;
    if (clock() > next + CLOCKS_PER_SEC)
      next = clock();
  }
}
