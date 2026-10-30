// SNAKE：グラフィック画面（320 × 200・256 色）のヘビのゲーム。8 × 8 ドットのマスで 40 × 23。
//   矢印か WASD で向きを変える、スペースで一時停止、ESC で終わり。
//   赤いえさは 10 点で 1 マス伸びる。ときどき出る金色のえさは 50 点で 3 マス伸びる（しばらくすると消える）。
//   長くなるほど速くなる。壁か自分にぶつかったら終わり（少し待ってから初めから）。
//   キーを押すまでは勝手に遊ぶ：えさに近づく向きのうち、行った先に自分の長さ以上の空きがある向きを選ぶ
#include <conio.h>
#include <gfx.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CELL 8
#define GW 40                           // マスの数
#define GH 23
#define TOP 16                          // 盤の上（その上は点数など）
#define MAXLEN (GW * GH)

static unsigned char buf[GFX_W * GFX_H];
static unsigned char occ[GH][GW];       // ヘビがいるマス
static short sx[MAXLEN], sy[MAXLEN];    // ヘビ（輪のように使う。head が頭、長さ len）
static int head, len, grow, dir, next_dir, score, best, dead_wait, paused, auto_play = 1;
static int fx, fy, gx = -1, gy, gold_time;   // えさ・金色のえさ（gx < 0 ならなし）

static const int DX[4] = {1, 0, -1, 0}, DY[4] = {0, 1, 0, -1};   // 右・下・左・上

// ---- 描く ----
static void box(int x, int y, int w, int h, int c) {
  for (int j = y; j < y + h; j++)
    memset(buf + j * GFX_W + x, c, w);
}

static const unsigned short digits[10] = {
  075557, 026222, 071747, 071717, 055711, 074717, 074757, 071111, 075757, 075717,
};
static void number(int x, int y, int n, int c) {
  char s[12];
  int k = 0;
  do { s[k++] = n % 10; n /= 10; } while (n);
  while (k--) {
    for (int r = 0; r < 5; r++)
      for (int i = 0; i < 3; i++)
        if (digits[(int)s[k]] >> ((4 - r) * 3 + (2 - i)) & 1)
          box(x + i * 2, y + r * 2, 2, 2, c);     // 2 倍の大きさで
    x += 8;
  }
}

// 色（標準のパレット：16〜231 は 6 × 6 × 6、232〜255 は灰色）
#define RGB6(r, g, b) (16 + (r) * 36 + (g) * 6 + (b))

static void cell(int x, int y, int c) { box(x * CELL + 1, TOP + y * CELL + 1, CELL - 2, CELL - 2, c); }

static void draw(void) {
  memset(buf, 0, sizeof(buf));
  // 枠と、マスの目（暗い点）
  box(0, TOP - 2, GFX_W, 1, 244);
  box(0, GFX_H - 1, GFX_W, 1, 244);
  for (int y = 0; y < GH; y++)
    for (int x = 0; x < GW; x++)
      buf[(TOP + y * CELL + CELL / 2) * GFX_W + x * CELL + CELL / 2] = 236;
  // 点数・いちばんよかった点数・長さ
  number(4, 2, score, 15);
  number(130, 2, len, RGB6(1, 5, 1));
  number(GFX_W - 60, 2, best, RGB6(5, 4, 0));
  // えさ（赤）と金色のえさ（点滅、消えそうになると速く）
  cell(fx, fy, RGB6(5, 0, 0));
  box(fx * CELL + 3, TOP + fy * CELL + 2, 1, 1, 15);
  if (gx >= 0 && (gold_time > 30 || gold_time / 3 % 2))
    cell(gx, gy, RGB6(5, 4, 0));
  // ヘビ：頭は明るい緑、しっぽに向かって暗く
  for (int i = 0; i < len; i++) {
    int k = (head - i + MAXLEN) % MAXLEN;
    int g = 5 - i * 3 / (len + 2);
    cell(sx[k], sy[k], i == 0 ? RGB6(3, 5, 3) : RGB6(0, g, g > 3 ? 1 : 0));
  }
  if (len) {                            // 目
    int x = sx[head] * CELL, y = TOP + sy[head] * CELL;
    box(x + 2, y + 2, 1, 1, 0);
    box(x + 5, y + 2, 1, 1, 0);
  }
  if (dead_wait) {                      // ぶつかった：頭を赤く
    cell(sx[head], sy[head], RGB6(5, 1, 1));
  }
  if (paused)
    for (int r = 0; r < 10; r++) {      // 一時停止の印
      box(156, 90 + r, 3, 1, 15);
      box(162, 90 + r, 3, 1, 15);
    }
}

// ---- 動き ----
static int free_cell(int x, int y) { return x >= 0 && x < GW && y >= 0 && y < GH && !occ[y][x]; }

// ヘビのいない、もう 1 つのえさ (ox, oy) でもないマスに
static void place_food(int *x, int *y, int ox, int oy) {
  do {
    *x = rand() % GW;
    *y = rand() % GH;
  } while (occ[*y][*x] || (*x == ox && *y == oy));
}

static void start(void) {
  memset(occ, 0, sizeof(occ));
  len = 0;
  head = 0;
  for (int i = 0; i < 4; i++) {         // 真ん中に右向きで 4 マス
    head = i;
    sx[head] = GW / 2 - 3 + i;
    sy[head] = GH / 2;
    occ[sy[head]][sx[head]] = 1;
    len++;
  }
  dir = next_dir = 0;
  grow = score = dead_wait = 0;
  gx = -1;
  place_food(&fx, &fy, -1, -1);
}

// (x, y) から行ける空きマスの数（max で打ち切り）。自動で遊ぶときの行き止まりよけ
static unsigned char seen[GH][GW];
static short qx[MAXLEN], qy[MAXLEN];
static int room(int x, int y, int max) {
  memset(seen, 0, sizeof(seen));
  int n = 0, q = 0;
  qx[n] = x; qy[n] = y; n++;
  seen[y][x] = 1;
  while (q < n && n < max) {
    int cx = qx[q], cy = qy[q];
    q++;
    for (int d = 0; d < 4; d++) {
      int nx = cx + DX[d], ny = cy + DY[d];
      if (free_cell(nx, ny) && !seen[ny][nx]) {
        seen[ny][nx] = 1;
        qx[n] = nx; qy[n] = ny; n++;
      }
    }
  }
  return n;
}

static void think(void) {
  int hx = sx[head], hy = sy[head], best_d = -1, best_score = -1000000;
  int tx = gx >= 0 ? gx : fx, ty = gx >= 0 ? gy : fy;   // 金色があればそちら
  for (int d = 0; d < 4; d++) {
    if (d == (dir + 2) % 4)
      continue;
    int nx = hx + DX[d], ny = hy + DY[d];
    if (!free_cell(nx, ny))
      continue;
    occ[ny][nx] = 1;                    // そこへ行ったとして、残りの空き
    int r = room(nx, ny, len + 8);
    occ[ny][nx] = 0;
    int s = -(abs(nx - tx) + abs(ny - ty)) + (r >= len + 8 ? 1000 : r * 10);
    if (d == dir)
      s += 1;                           // 同じならまっすぐ
    if (s > best_score) { best_score = s; best_d = d; }
  }
  if (best_d >= 0)
    next_dir = best_d;
}

static void step(void) {
  dir = next_dir;
  int nx = sx[head] + DX[dir], ny = sy[head] + DY[dir];
  // しっぽはこの動きで空くので、しっぽのマスへは進める
  int tail = (head - len + 1 + MAXLEN) % MAXLEN;
  int tail_moves = grow == 0;
  if (nx < 0 || nx >= GW || ny < 0 || ny >= GH ||
      (occ[ny][nx] && !(tail_moves && nx == sx[tail] && ny == sy[tail]))) {
    dead_wait = 60;                     // ぶつかった
    if (score > best)
      best = score;
    return;
  }
  if (tail_moves)
    occ[sy[tail]][sx[tail]] = 0;
  else {
    grow--;
    len++;
  }
  head = (head + 1) % MAXLEN;
  sx[head] = nx;
  sy[head] = ny;
  occ[ny][nx] = 1;
  if (nx == fx && ny == fy) {
    score += 10;
    grow += 1;
    place_food(&fx, &fy, gx, gy);
    if (gx < 0 && rand() % 4 == 0) {    // ときどき金色のえさ
      place_food(&gx, &gy, fx, fy);
      gold_time = 90;
    }
  }
  if (nx == gx && ny == gy) {
    score += 50;
    grow += 3;
    gx = -1;
  }
}

int main(void) {
  gfx_mode(1);
  srand(clock());
  start();
  clock_t next = clock();
  int tick = 0;
  for (;;) {
    while (kbhit()) {
      int k = getch(), d = -1;
      if (k == KEY_ESC)
        return 0;
      if (auto_play) {                  // キーを押したら、自分で遊ぶ（初めから）
        auto_play = 0;
        start();
      }
      if (k == KEY_RIGHT || k == 'd' || k == 'D') d = 0;
      if (k == KEY_DOWN || k == 's' || k == 'S') d = 1;
      if (k == KEY_LEFT || k == 'a' || k == 'A') d = 2;
      if (k == KEY_UP || k == 'w' || k == 'W') d = 3;
      if (k == ' ')
        paused = !paused;
      if (d >= 0 && d != (dir + 2) % 4)   // 真後ろには曲がれない
        next_dir = d;
    }
    // 1 秒に 60 回まわし、長さに合わせて何回かに 1 回進める（8 マス/秒 → 20 マス/秒）
    int every = 8 - len / 12;
    if (every < 3)
      every = 3;
    if (dead_wait) {
      if (--dead_wait == 0)
        start();
    } else if (!paused && ++tick >= every) {
      tick = 0;
      if (auto_play)
        think();
      step();
      if (gx >= 0 && --gold_time <= 0)
        gx = -1;
    }
    draw();
    gfx_present(buf);
    next += CLOCKS_PER_SEC / 60;
    while (clock() < next)
      ;
    if (clock() > next + CLOCKS_PER_SEC)
      next = clock();
  }
}
