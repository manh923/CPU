// libc/math.c のテスト：PC の gcc で一緒にビルドし、glibc の long double の関数（sinl など。double より正確）と比べる。
// 誤差を ulp（double の最後の桁）で測り、関数ごとの最大を出す。test/run.js が動かす
//   gcc -O2 -fno-builtin -fno-math-errno -o mathtest test/mathtest.c libc/math.c -lm && ./mathtest [回数]
// sqrt・fmod・floor などは 0 ulp（正しく丸める・正確）でないといけない。ほかは表の上限まで
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned long long u64;

static u64 state = 88172645463325252ULL;
static u64 rnd(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}
static double bitsd(u64 u) { double d; memcpy(&d, &u, 8); return d; }
static double uni(double a, double b) { return a + (b - a) * (double)(rnd() >> 11) * 0x1p-53; }
static double anyd(void) { return bitsd(rnd() & 0x7FEFFFFFFFFFFFFFULL); }   // 有限の正の数
static double sgn(double x) { return rnd() & 1 ? -x : x; }

// got と want（long double）の差が double の何 ulp か。NaN・inf はどちらも同じなら 0
static double ulps(double got, long double want) {
  if (isnan(got) && isnan(want)) return 0;
  double w = (double)want;
  if (isinf(w) || isinf(got)) return got == w ? 0 : 1e9;
  if (isinf(w)) w = copysign(0x1.fffffffffffffp1023, w);
  int e;
  frexp(w, &e);
  long double ulp = ldexpl(1.0L, (e - 53 < -1074 ? -1074 : e - 53));
  return (double)(fabsl((long double)got - want) / ulp);
}

typedef struct {
  const char *name;
  double limit;
  double worst;
  double wx, wy;
} Stat;

static int ng;
static void rec(Stat *s, double err, double x, double y) {
  if (err > s->worst) {
    s->worst = err;
    s->wx = x;
    s->wy = y;
  }
}

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 200000;
  Stat st[] = {
    {"sqrt", 0}, {"fmod", 0}, {"floor", 0}, {"ceil", 0}, {"trunc", 0}, {"round", 0}, {"ldexp", 0}, {"frexp", 0},
    {"exp", 1}, {"log", 1}, {"log10", 1}, {"log2", 1}, {"pow", 2}, {"sin", 1.5}, {"cos", 1.5}, {"tan", 3},
    {"atan", 1}, {"atan2", 2}, {"asin", 3}, {"acos", 3}, {"sinh", 3}, {"cosh", 2}, {"tanh", 3},
    {"expm1", 2}, {"log1p", 1}, {"cbrt", 1}, {"hypot", 2},
  };
  enum { SQRT, FMOD, FLOOR, CEIL, TRUNC, ROUND, LDEXP, FREXP, EXP, LOG, LOG10, LOG2, POW, SIN, COS, TAN,
         ATAN, ATAN2, ASIN, ACOS, SINH, COSH, TANH, EXPM1, LOG1P, CBRT, HYPOT, NFN };

  for (long i = 0; i < n; i++) {
    double a = anyd(), b = anyd(), x, y;
    int e1, e2;
    // 正確なもの
    x = rnd() & 1 ? a : bitsd(rnd() % (1ULL << 52));
    rec(&st[SQRT], ulps(sqrt(x), __builtin_sqrt(x)), x, 0);
    x = sgn(rnd() % 3 ? uni(-1e6, 1e6) : a), y = sgn(rnd() % 3 ? uni(0.001, 1000) : b);
    rec(&st[FMOD], ulps(fmod(x, y), fmodl(x, y)), x, y);
    x = sgn(rnd() % 2 ? uni(0, 1e6) : a);
    rec(&st[FLOOR], ulps(floor(x), floorl(x)), x, 0);
    rec(&st[CEIL], ulps(ceil(x), ceill(x)), x, 0);
    rec(&st[TRUNC], ulps(trunc(x), truncl(x)), x, 0);
    x = rnd() % 2 ? sgn((double)(rnd() % 100000) / 2) : x;
    rec(&st[ROUND], ulps(round(x), roundl(x)), x, 0);
    x = sgn(rnd() % 2 ? a : bitsd(rnd() % (1ULL << 52)));
    int k = (int)(rnd() % 2200) - 1100;
    rec(&st[LDEXP], ulps(ldexp(x, k), (long double)(double)ldexpl(x, k)), x, k);
    double m1 = frexp(x, &e1);
    long double m2 = frexpl(x, &e2);
    rec(&st[FREXP], m1 == m2 && e1 == e2 ? 0 : 1e9, x, 0);

    // 近いもの
    x = rnd() % 4 ? uni(-745, 710) : uni(-1, 1);
    rec(&st[EXP], ulps(exp(x), expl(x)), x, 0);
    x = rnd() % 3 ? a : uni(0.5, 2);
    rec(&st[LOG], ulps(log(x), logl(x)), x, 0);
    rec(&st[LOG10], ulps(log10(x), log10l(x)), x, 0);
    rec(&st[LOG2], ulps(log2(x), log2l(x)), x, 0);
    x = rnd() % 3 ? uni(0, 100) : uni(0.9, 1.1), y = rnd() % 4 ? uni(-50, 50) : (double)((int)(rnd() % 61) - 30);
    if (rnd() % 4 == 0) { x = uni(1e-300, 1e300); y = uni(-1, 1); }
    if (rnd() % 8 == 0) { x = -x; y = (double)((int)(rnd() % 61) - 30); }
    rec(&st[POW], ulps(pow(x, y), powl(x, y)), x, y);
    x = sgn(rnd() % 3 ? uni(0, 1e5) : uni(0, 4));
    rec(&st[SIN], ulps(sin(x), sinl(x)), x, 0);
    rec(&st[COS], ulps(cos(x), cosl(x)), x, 0);
    rec(&st[TAN], ulps(tan(x), tanl(x)), x, 0);
    x = sgn(rnd() % 2 ? a : uni(0, 4));
    rec(&st[ATAN], ulps(atan(x), atanl(x)), x, 0);
    x = sgn(uni(-100, 100)), y = sgn(rnd() % 2 ? uni(-100, 100) : a);
    rec(&st[ATAN2], ulps(atan2(y, x), atan2l(y, x)), y, x);
    x = uni(-1, 1);
    rec(&st[ASIN], ulps(asin(x), asinl(x)), x, 0);
    rec(&st[ACOS], ulps(acos(x), acosl(x)), x, 0);
    x = rnd() % 2 ? uni(-50, 50) : uni(-1, 1);
    rec(&st[SINH], ulps(sinh(x), sinhl(x)), x, 0);
    rec(&st[COSH], ulps(cosh(x), coshl(x)), x, 0);
    rec(&st[TANH], ulps(tanh(x), tanhl(x)), x, 0);
    rec(&st[EXPM1], ulps(expm1(x), expm1l(x)), x, 0);
    x = rnd() % 2 ? uni(-0.999, 10) : uni(-1e-3, 1e-3);
    rec(&st[LOG1P], ulps(log1p(x), log1pl(x)), x, 0);
    x = sgn(rnd() % 2 ? a : uni(0, 100));
    rec(&st[CBRT], ulps(cbrt(x), cbrtl(x)), x, 0);
    x = sgn(uni(0, 1e10)), y = sgn(rnd() % 2 ? uni(0, 1e10) : a);
    rec(&st[HYPOT], ulps(hypot(x, y), hypotl(x, y)), x, y);
  }

  // 特別な値
  struct { double got; long double want; const char *what; } sp[] = {
    {sqrt(-1.0), NAN, "sqrt(-1)"}, {sqrt(-0.0), -0.0, "sqrt(-0)"}, {sqrt(INFINITY), INFINITY, "sqrt(inf)"},
    {exp(1000), INFINITY, "exp(1000)"}, {exp(-1000), 0, "exp(-1000)"}, {log(0), -INFINITY, "log(0)"},
    {log(-1), NAN, "log(-1)"}, {pow(2, 10), 1024, "pow(2,10)"}, {pow(10, 22), 1e22L, "pow(10,22)"},
    {pow(-2, 3), -8, "pow(-2,3)"}, {pow(0, -1), INFINITY, "pow(0,-1)"}, {pow(-8, 1.0 / 3), NAN, "pow(-8,1/3)"},
    {pow(2, 0.5), 1.41421356237309504880L, "pow(2,.5)"}, {atan2(0, -1), 3.14159265358979323846L, "atan2(0,-1)"},
    {log10(1000), 3, "log10(1000)"}, {log2(1024), 10, "log2(1024)"}, {fmod(5.5, 2), 1.5, "fmod(5.5,2)"},
    {round(-2.5), -3, "round(-2.5)"}, {floor(-0.5), -1, "floor(-.5)"}, {cbrt(27), 3, "cbrt(27)"},
    {hypot(3, 4), 5, "hypot(3,4)"}, {ldexp(1, -1074), 0x1p-1074L, "ldexp(1,-1074)"}, {ldexp(1, 1024), INFINITY, "ldexp(1,1024)"},
  };
  for (int i = 0; i < (int)(sizeof(sp) / sizeof(*sp)); i++) {
    double g = sp[i].got;   // 答えは double に丸めて比べる
    long double w = sp[i].want;
    int ok = (isnan(g) && isnan(w)) || (g == (double)w && !signbit(g) == !signbit(w));
    if (!ok) {
      printf("NG %s = %a（%La のはず）\n", sp[i].what, g, w);
      ng++;
    }
  }

  for (int i = 0; i < NFN; i++) {
    int bad = st[i].worst > st[i].limit;
    if (bad) ng++;
    if (bad || argc > 2)
      printf("%s %-6s 最大 %.3g ulp（上限 %g）x=%a y=%a\n", bad ? "NG" : "ok", st[i].name, st[i].worst, st[i].limit,
             st[i].wx, st[i].wy);
  }
  printf("mathtest: %ld 回 x %d 関数, %d NG\n", n, NFN, ng);
  return ng != 0;
}
