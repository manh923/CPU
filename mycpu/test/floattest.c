// libc/softfloat.c のテスト：PC の gcc で libc/softfloat.c と一緒にビルドし、PC の浮動小数点の計算と
// ビット単位で比べる（NaN はどれも NaN なら同じとする）。test/run.js が動かす
//   gcc -O2 -o floattest test/floattest.c libc/softfloat.c && ./floattest [回数]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned u32;
typedef unsigned long long u64;
typedef long long i64;

u64 __adddf3(u64, u64);
u64 __subdf3(u64, u64);
u64 __muldf3(u64, u64);
u64 __divdf3(u64, u64);
int __mycpu_dcmp(u64, u64);
u32 __addsf3(u32, u32);
u32 __subsf3(u32, u32);
u32 __mulsf3(u32, u32);
u32 __divsf3(u32, u32);
int __mycpu_fcmp(u32, u32);
u64 __floatdidf(i64);
u64 __floatundidf(u64);
u64 __floatsidf(int);
u64 __floatunsidf(u32);
i64 __fixdfdi(u64);
u64 __fixunsdfdi(u64);
int __fixdfsi(u64);
u32 __fixunsdfsi(u64);
u64 __extendsfdf2(u32);
u32 __truncdfsf2(u64);
u32 __floatsisf(int);
u32 __floatunsisf(u32);
u32 __floatdisf(i64);
u32 __floatundisf(u64);
int __fixsfsi(u32);
i64 __fixsfdi(u32);

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
static float bitsf(u32 u) { float f; memcpy(&f, &u, 4); return f; }

static int dnan(u64 x) { return ((x >> 52) & 0x7ff) == 0x7ff && (x << 12); }
static int fnan(u32 x) { return ((x >> 23) & 0xff) == 0xff && (x << 9); }

static u64 specials_d[] = {
  0, 0x8000000000000000ULL, 0x3FF0000000000000ULL, 0xBFF0000000000000ULL, 0x7FF0000000000000ULL, 0xFFF0000000000000ULL,
  0x7FF8000000000000ULL, 1, 0x800FFFFFFFFFFFFFULL, 0x0010000000000000ULL, 0x7FEFFFFFFFFFFFFFULL, 0x3FE0000000000000ULL,
  0x4340000000000000ULL, 0x43E0000000000000ULL, 0xC3E0000000000000ULL, 0x41E0000000000000ULL, 0x3CB0000000000000ULL,
};

// いろいろな double：特別な値、ランダムなビット列、指数を近くにしたもの、1 前後
static u64 rand_d(void) {
  switch (rnd() % 6) {
  case 0: return specials_d[rnd() % (sizeof(specials_d) / 8)];
  case 1: return rnd();
  case 2: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(1023 + (int)(rnd() % 40) - 20) << 52);
  case 3: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(rnd() % 60) << 52);          // 非正規化数の近く
  case 4: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(2046 - rnd() % 60) << 52);   // 最大の近く
  default: return dbits((double)(i64)(rnd() % 2000001) - 1000000.0) ^ (rnd() & 7);
  }
}

static u32 rand_f(void) {
  switch (rnd() % 4) {
  case 0: return __truncdfsf2(specials_d[rnd() % (sizeof(specials_d) / 8)]);
  case 1: return (u32)rnd();
  case 2: return ((u32)rnd() & 0x807FFFFF) | ((u32)(127 + (int)(rnd() % 30) - 15) << 23);
  default: return ((u32)rnd() & 0x807FFFFF) | ((u32)(rnd() % 30) << 23);
  }
}

static int ng;
static void report(const char *what, u64 a, u64 b, u64 got, u64 want) {
  if (ng++ < 20)
    printf("NG %s %016llx %016llx: got %016llx want %016llx\n", what, a, b, got, want);
}

#define CHECK_D(name, expr_soft, expr_hw)                                        \
  do {                                                                            \
    u64 g = (expr_soft), w = dbits(expr_hw);                                      \
    if (g != w && !(dnan(g) && dnan(w)))                                          \
      report(name, a, b, g, w);                                                   \
  } while (0)

#define CHECK_F(name, expr_soft, expr_hw)                                        \
  do {                                                                            \
    u32 g = (expr_soft), w = fbits(expr_hw);                                      \
    if (g != w && !(fnan(g) && fnan(w)))                                          \
      report(name, fa, fb, g, w);                                                 \
  } while (0)

static int cmp_hw(double x, double y) { return x != x || y != y ? 2 : x < y ? -1 : x > y ? 1 : 0; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000000;
  for (long i = 0; i < n; i++) {
    u64 a = rand_d(), b = rand_d();
    double x = bitsd(a), y = bitsd(b);
    CHECK_D("add", __adddf3(a, b), x + y);
    CHECK_D("sub", __subdf3(a, b), x - y);
    CHECK_D("mul", __muldf3(a, b), x * y);
    CHECK_D("div", __divdf3(a, b), x / y);
    if (__mycpu_dcmp(a, b) != cmp_hw(x, y))
      report("dcmp", a, b, __mycpu_dcmp(a, b), cmp_hw(x, y));

    i64 iv = (i64)rnd() >> (rnd() % 64);
    CHECK_D("floatdidf", __floatdidf(iv), (double)iv);
    CHECK_D("floatundidf", __floatundidf((u64)iv), (double)(u64)iv);
    CHECK_D("floatsidf", __floatsidf((int)iv), (double)(int)iv);
    CHECK_D("floatunsidf", __floatunsidf((u32)iv), (double)(u32)iv);
    if (!dnan(a) && x > -9.2e18 && x < 9.2e18 && __fixdfdi(a) != (i64)x)
      report("fixdfdi", a, 0, __fixdfdi(a), (i64)x);
    if (!dnan(a) && x >= 0 && x < 1.8e19 && __fixunsdfdi(a) != (u64)x)
      report("fixunsdfdi", a, 0, __fixunsdfdi(a), (u64)x);
    if (!dnan(a) && x > -2.1e9 && x < 2.1e9 && __fixdfsi(a) != (int)x)
      report("fixdfsi", a, 0, __fixdfsi(a), (int)x);
    if (!dnan(a) && x >= 0 && x < 4.2e9 && __fixunsdfsi(a) != (u32)x)
      report("fixunsdfsi", a, 0, __fixunsdfsi(a), (u32)x);

    u32 fa = rand_f(), fb = rand_f();
    float fx = bitsf(fa), fy = bitsf(fb);
    CHECK_F("addsf", __addsf3(fa, fb), fx + fy);
    CHECK_F("subsf", __subsf3(fa, fb), fx - fy);
    CHECK_F("mulsf", __mulsf3(fa, fb), fx * fy);
    CHECK_F("divsf", __divsf3(fa, fb), fx / fy);
    if (__mycpu_fcmp(fa, fb) != cmp_hw(fx, fy))
      report("fcmp", fa, fb, __mycpu_fcmp(fa, fb), cmp_hw(fx, fy));
    CHECK_D("extendsfdf2", __extendsfdf2(fa), (double)fx);
    CHECK_F("truncdfsf2", __truncdfsf2(a), (float)x);
    CHECK_F("floatsisf", __floatsisf((int)iv), (float)(int)iv);
    CHECK_F("floatunsisf", __floatunsisf((u32)iv), (float)(u32)iv);
    CHECK_F("floatdisf", __floatdisf(iv), (float)iv);
    CHECK_F("floatundisf", __floatundisf((u64)iv), (float)(u64)iv);
    if (!fnan(fa) && fx > -2.1e9f && fx < 2.1e9f && __fixsfsi(fa) != (int)fx)
      report("fixsfsi", fa, 0, __fixsfsi(fa), (int)fx);
    if (!fnan(fa) && fx > -9.2e18f && fx < 9.2e18f && __fixsfdi(fa) != (i64)fx)
      report("fixsfdi", fa, 0, __fixsfdi(fa), (i64)fx);
  }
  printf("floattest: %ld x 28 checks, %d NG\n", n, ng);
  return ng != 0;
}
