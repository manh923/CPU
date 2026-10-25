// libc/fltio.c のテスト：PC の gcc で一緒にビルドし、glibc の printf・strtod と比べる。test/run.js が動かす
//   gcc -O2 -Dstrtod=my_strtod -Dstrtof=my_strtof -Dstrtold=my_strtold -Datof=my_atof
//       -o fltiotest test/fltiotest.c libc/fltio.c && ./fltiotest [回数]
//   1. %f・%e・%g（精度いろいろ、# あり）の文字列が同じ
//   2. strtod：%.17g の文字列・ランダムな数字の列・ちょうど真ん中の値（とその前後）で、結果のビット列が同じ
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

typedef unsigned long long u64;

int __mycpu_dtoa(double x, int conv, int prec, int alt, char *out);
double my_strtod(const char *s, char **end);

static u64 state = 88172645463325252ULL;
static u64 rnd(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

static u64 dbits(double d) { u64 u; memcpy(&u, &d, 8); return u; }
static double bitsd(u64 u) { double d; memcpy(&d, &u, 8); return d; }

static double rand_d(void) {
  switch (rnd() % 5) {
  case 0: return bitsd(rnd() & 0x7FFFFFFFFFFFFFFFULL);
  case 1: return bitsd((rnd() & 0x000FFFFFFFFFFFFFULL) | ((u64)(1023 + (int)(rnd() % 80) - 40) << 52));
  case 2: return (double)(rnd() % 100000) / (double)(1 + rnd() % 1000);
  case 3: return (double)(rnd() % 1000000) * 0.5 + (rnd() % 2 ? 0.25 : 0.125);   // ちょうど真ん中になりやすい
  default: return bitsd(rnd() % 100000);                                          // 非正規化数
  }
}

static int ng;
static char got[4000], want[4000];

static void check_fmt(double x, int conv, int prec, int alt) {
  char f[16];
  sprintf(f, "%%%s.%d%c", alt ? "#" : "", prec, conv);
  if (((dbits(x) >> 52) & 0x7FF) == 0x7FF)     // inf・NaN は stdio.c が出す
    return;
  snprintf(want, sizeof(want), f, x);
  __mycpu_dtoa(x, conv, prec, alt, got);
  // glibc は %#.2g で 99.5 を「1.e+02」にする（規格どおりなら精度 1 で「1.0e+02」）。そこは比べない
  if (alt && (conv | 0x20) == 'g' && (strstr(want, ".e") || strstr(want, ".E")))
    return;
  if (strcmp(got, want) && ng++ < 20)
    printf("NG %s %a: got %s want %s\n", f, x, got, want);
}

static void check_strtod(const char *s) {
  errno = 0;
  char *e1, *e2;
  double w = strtod(s, &e1);
  double g = my_strtod(s, &e2);
  if ((dbits(g) != dbits(w) || e1 != e2) && ng++ < 20)
    printf("NG strtod %.60s: got %a want %a (end %d %d)\n", s, g, w, (int)(e2 - s), (int)(e1 - s));
}

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 100000;
  static const char *fixed[] = {
    "0", "-0", "1", "0.1", "1e308", "1.8e308", "4.9e-324", "2.4e-324", "2.5e-324", "1e-400", "0x1p-1074",
    "0x1.fffffffffffffp1023", "0x1.fffffffffffff8p1023", "inf", "-Infinity", "nan", "NaN(123)", ".5", "5.", "1e",
    "1e+", "abc", "  +12.5e-3xyz", "0x", "0x.8p1", "123456789012345678901234567890", "2.2250738585072011e-308",
    "2.2250738585072012e-308", "9007199254740993", "9007199254740992.5", "1.00000000000000011102230246251565404236316680908203125",
  };
  for (int i = 0; i < (int)(sizeof(fixed) / sizeof(*fixed)); i++)
    check_strtod(fixed[i]);
  double fx[] = {0.0, 0.5, 1.5, 2.5, 0.125, 9.9999, 99.5, 1e-5, 1e-4, 123456.0, 1e15, 1e16, 1e300, 5e-324, 1.7976931348623157e308};
  for (int i = 0; i < (int)(sizeof(fx) / sizeof(*fx)); i++)
    for (int p = 0; p < 20; p++) {
      check_fmt(fx[i], 'f', p, 0);
      check_fmt(fx[i], 'e', p, 0);
      check_fmt(fx[i], 'g', p, 0);
      check_fmt(fx[i], 'g', p, 1);
      check_fmt(fx[i], 'E', p, 1);
    }

  char buf[1200];
  for (long i = 0; i < n; i++) {
    double x = rand_d();
    int p = rnd() % 25;
    static const char convs[] = "feEgG";
    int conv = convs[rnd() % 5];
    if (conv == 'f' && x > 1e30 && rnd() % 4)
      x = 1.0 / x;
    check_fmt(x, conv, p, rnd() % 4 == 0);

    // strtod
    sprintf(buf, "%.17g", x);
    check_strtod(buf);
    sprintf(buf, "%.*e", (int)(rnd() % 20), x);
    check_strtod(buf);
    // ちょうど真ん中（long double なら正確に表せる）と、最後の桁を少し動かしたもの
    double y = bitsd(dbits(x) + 1);
    long double mid = ((long double)x + (long double)y) / 2;
    int len = sprintf(buf, "%.780Le", mid);
    char *e = strchr(buf, 'e');
    if (e) {                                  // y が inf なら飛ばす
      char *last = e - 1;
      while (*last == '0')
        last--;
      check_strtod(buf);
      char c = *last;
      if (c > '0') { *last = c - 1; check_strtod(buf); }
      if (c < '9') { *last = c + 1; check_strtod(buf); }
      *last = c;
    }
    (void)len;
    // ランダムな数字の列
    int nd = 1 + rnd() % 30, k = 0;
    for (int j = 0; j < nd; j++)
      buf[k++] = '0' + rnd() % 10;
    if (rnd() % 2)
      buf[1 + rnd() % nd] = '.';
    k += sprintf(buf + k, "e%d", (int)(rnd() % 700) - 350);
    check_strtod(buf);
  }
  printf("fltiotest: %ld 回, %d NG\n", n, ng);
  return ng != 0;
}
