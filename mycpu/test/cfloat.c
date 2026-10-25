// 浮動小数点の通しのテスト：同じプログラムを
//   1. この CPU 向けに cc/ でコンパイルして、シミュレータで動かす（libc/softfloat.c・fltio.c・math.c を使う）
//   2. PC の gcc でコンパイルして動かす（計算は PC の FPU、printf・strtod は glibc、数学の関数だけ libc/math.c）
// 出力がまったく同じになるはず（IEEE 754 どおりなら、どちらも同じビット列になる）。test/run.js が比べる
//   gcc -O0 -ffp-contract=off -fno-builtin -o cfloat test/cfloat.c libc/math.c -lm
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned long long u64;
typedef unsigned int u32;

static u64 state = 88172645463325252ULL;
static u64 rnd(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

static u64 dbits(double d) { u64 u; memcpy(&u, &d, 8); return u; }
static double bitsd(u64 u) { double d; memcpy(&d, &u, 8); return d; }
static u32 fbits(float f) { u32 u; memcpy(&u, &f, 4); return u; }

// 結果のビット列をまとめるハッシュ（FNV-1a）。NaN は符号・中身が CPU で違うので、まとめて 1 つの値にする
static u64 hash = 14695981039346656037ULL;
static void mix(u64 v) {
  for (int i = 0; i < 8; i++) {
    hash = (hash ^ (v & 0xFF)) * 1099511628211ULL;
    v >>= 8;
  }
}
static void mixd(double d) { mix(d != d ? 0x7FF8000000000000ULL : dbits(d)); }
static void mixf(float f) { mix(f != f ? 0x7FC00000 : fbits(f)); }
static void mixs(const char *s) {
  for (; *s; s++)
    hash = (hash ^ (unsigned char)*s) * 1099511628211ULL;
}

// （1 つの式で rnd() を 2 回呼ぶと、どちらが先かがコンパイラで違うので分ける）
static double rand_d(void) {
  u64 m;
  switch (rnd() % 5) {
  case 0: return bitsd(rnd());
  case 1:
    m = rnd() & 0x800FFFFFFFFFFFFFULL;
    return bitsd(m | ((u64)(1023 + (int)(rnd() % 60) - 30) << 52));
  case 2: return (double)(int)(rnd() % 20001 - 10000) / 16;
  case 3: return (double)(int)(rnd() % 2001 - 1000);
  default: return bitsd(rnd() % 4096);
  }
}

struct pt { float x; double y; };
static struct pt mkpt(float x, double y) { struct pt p = {x, y}; return p; }
static double sum3(double a, float b, double c) { return a + b + c; }
static double vsum(int n, ...);

int main(void) {
  // 読みやすい値をいくつか（ずれたらすぐ分かるように）
  printf("%.17g %.17g %.17g\n", 0.1 + 0.2, 1.0 / 3, 2.0 / 3 * 3);
  printf("%f %e %g %g %g\n", 3.14159265358979, 6.02214076e23, 1e-5, 123456789.0, 0.0001);
  printf("%.3f %10.4f %-10.2e| %+g %08.3f\n", 2.5, -1.0 / 7, 12345.678, 42.0, -3.14159);
  printf("%.0f %.0f %.0f %.0f %#.0f %#g\n", 0.5, 1.5, 2.5, -0.5, 3.0, 1.0);
  printf("%g %g %g %g\n", 1.0 / 0.0, -1.0 / 0.0, 0.0 / 0.0 != 0.0 / 0.0 ? 1.0 : 0.0, -0.0);
  printf("%.10f %.10f %.10f %.10f\n", sqrt(2), exp(1), log(10), pow(2, 0.5));
  printf("%.15g %.15g %.15g %.15g\n", sin(1), cos(1), tan(1), atan2(1, -1));
  printf("%.15g %.15g %.15g\n", floor(-2.5), ceil(-2.5), fmod(10.5, 3));
  float f = 1.1f;
  printf("%.9g %.9g %.9g %d\n", f, f * f, f / 3, (int)(f * 100));
  struct pt p = mkpt(1.5f, 2.25);
  printf("%g %g %g %g\n", p.x, p.y, sum3(1, 2.5f, 3), vsum(4, 1.0, 2.0, 3.5, 4.25));
  char *end;
  double pi5 = strtod("3.14159xyz", &end);
  printf("%.17g %.17g %.17g %s\n", pi5, atof("1e100"), strtod("0x1.8p1", 0), end);
  long long ll = (long long)1e18;
  unsigned long long ull = 18000000000000000000ULL;
  printf("%lld %.17g %.17g %d %u\n", ll, (double)ll, (double)ull, (int)-3.99, (unsigned)3e9);
  printf("%d %d %d %d %d\n", 0.1 < 0.2, 0.0 == -0.0, (0.0 / 0.0) == (0.0 / 0.0), 1.0f > 0.5, !0.0);

  // ランダムな値で、計算・比べる・変換・printf・strtod・数学の関数を通す
  char buf[400];
  for (int i = 0; i < 40; i++) {
    double a = rand_d(), b = rand_d();
    float fa = (float)a, fb = (float)b;
    mixd(a + b); mixd(a - b); mixd(a * b); mixd(a / b);
    mix((a < b) | (a <= b) << 1 | (a == b) << 2 | (a != b) << 3 | (a > b) << 4 | (a >= b) << 5);
    mixf(fa + fb); mixf(fa - fb); mixf(fa * fb); mixf(fa / fb);
    mix((fa < fb) | (fa == fb) << 1);
    mixd(fa); mixf((float)b);
    if (a > -2e9 && a < 2e9) mix((u64)(long long)(int)a);
    if (a > -9e18 && a < 9e18) mix((u64)(long long)a);
    if (a >= 0 && a < 4e9) mix((unsigned)a);
    long long r = (long long)rnd();
    mixd((double)r); mixd((double)(u64)r); mixd((double)(int)r); mixd((double)(unsigned)r); mixf((float)r);
    mixd(-a); mixd(a ? 1.0 : 2.0);

    sprintf(buf, "%.17g|%.3e|%g|%.1f", a, b, a * 1e-3, fmod(a, 1000.0));
    mixs(buf);
    mixd(strtod(buf, 0));
    double c = rand_d();
    double ac = fabs(c);
    mixd(sqrt(ac)); mixd(floor(c)); mixd(ceil(c)); mixd(round(c)); mixd(fmod(c, 7.5));
    double s = fmod(c, 100.0);
    mixd(sin(s)); mixd(cos(s)); mixd(atan(c)); mixd(exp(s / 10)); mixd(log(ac)); mixd(pow(ac, 0.3));
    if (i % 10 == 0)
      printf("%d: %s %016llx\n", i, buf, hash);
  }
  printf("hash %016llx\n", hash);
  return 0;
}

#include <stdarg.h>
static double vsum(int n, ...) {
  va_list ap;
  va_start(ap, n);
  double s = 0;
  for (int i = 0; i < n; i++)
    s += va_arg(ap, double);
  va_end(ap);
  return s;
}
