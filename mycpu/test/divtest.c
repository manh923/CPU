// 定数で割る式（コンパイラが掛け算の上位とシフトに変える）が、割り算の命令と同じ答えになるか。
// 割る数を変数に入れたもの（割り算の命令になる）と比べる。test/run.js が test/cctest.js の runC で動かす
#include <stdio.h>
#include <limits.h>

static unsigned state = 2463534242u;
static unsigned rnd(void) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

static int xs[64 + 3000];
static int nx, ng, n;

static void fail(const char *what, long long c, int x, long long got, long long want) {
  if (ng++ < 20)
    printf("NG %s c=%lld x=%d: got %lld want %lld\n", what, c, x, got, want);
}

// 符号付き・符号なしの / と %。a[] を使う形（作業用レジスタが少ないとき）や、レジスタの変数どうしの形も
#define T(c) do {                                                                 \
    int sd = (c);                                                                 \
    unsigned ud = (unsigned)(c);                                                  \
    for (int i = 0; i < nx; i++) {                                                \
      int x = xs[i];                                                              \
      unsigned ux = x;                                                            \
      n++;                                                                        \
      if ((int)(c) != 0 && !((int)(c) == -1 && x == INT_MIN)) {                   \
        if (x / (int)(c) != x / sd) fail("div", (int)(c), x, x / (int)(c), x / sd); \
        if (x % (int)(c) != x % sd) fail("mod", (int)(c), x, x % (int)(c), x % sd); \
        int a = xs[i] / (int)(c) + xs[(i + 1) % nx] % (int)(c);                  \
        if (a != x / sd + xs[(i + 1) % nx] % sd) fail("mix", (int)(c), x, a, 0);  \
      }                                                                           \
      if (ux / (unsigned)(c) != ux / ud) fail("udiv", (unsigned)(c), x, ux / (unsigned)(c), ux / ud); \
      if (ux % (unsigned)(c) != ux % ud) fail("umod", (unsigned)(c), x, ux % (unsigned)(c), ux % ud); \
      xs[i] = xs[i] / (int)((c) | 1) * 1 + (x - x);   /* 自分に代入する形（dst = lr） */ \
      if (xs[i] != x / (sd | 1)) fail("self", (c) | 1, x, xs[i], x / (sd | 1));   \
      xs[i] = x;                                                                  \
    }                                                                             \
  } while (0)

int main(void) {
  int edge[] = {0, 1, -1, 2, -2, 3, -3, 7, -7, 9, 10, 11, -9, -10, -11, 99, 100, 101, -100, 255, 256,
                1000, -1000, 65535, 65536, -65536, 1 << 30, -(1 << 30), INT_MAX, INT_MIN, INT_MAX - 1, INT_MIN + 1};
  for (int i = 0; i < (int)(sizeof(edge) / sizeof(edge[0])); i++)
    xs[nx++] = edge[i];
  for (int i = 0; i < 3000; i++) {
    unsigned r = rnd();
    xs[nx++] = i % 3 == 0 ? (int)r : i % 3 == 1 ? (int)(r >> (r % 31)) : -(int)(r >> (r % 31));
  }
  T(2); T(3); T(4); T(5); T(6); T(7); T(8); T(9); T(10); T(11); T(12); T(13); T(14); T(15); T(16);
  T(17); T(19); T(23); T(24); T(25); T(31); T(32); T(37); T(40); T(60); T(64); T(100); T(125); T(127);
  T(128); T(255); T(256); T(320); T(360); T(641); T(1000); T(1023); T(1024); T(3600); T(7919); T(10000);
  T(65535); T(65536); T(86400); T(100000); T(1000000); T(1000000000); T(0x12345678); T(0x40000000);
  T(0x7FFFFFFF); T(0x80000000); T(0x80000001); T(0xFFFFFFFE); T(0xFFFFFFFF); T(0xC0000000);
  T(-2); T(-3); T(-4); T(-5); T(-7); T(-8); T(-10); T(-16); T(-100); T(-641); T(-1000); T(-65536);
  T(-0x7FFFFFFF); T(1); T(-1);
  printf("divtest: %d 組、%d 件 NG\n", n, ng);
  return ng != 0;
}
