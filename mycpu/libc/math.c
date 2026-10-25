// 数学の関数（math.h）。double で計算する（float の版は double で計算して丸める）
//   sqrt・fmod・floor・ceil・trunc・round・ldexp・frexp・modf・fabs は正確（正しく丸める）
//   exp・log・sin・cos・atan などは多項式で近く（誤差は 1〜2 ulp ほど。係数は fdlibm と同じもの）
// 整数の計算とふつうの演算だけなので、PC の gcc でもビルドできる（test/mathtest.c が glibc と比べる）
#include <math.h>
#include <string.h>

typedef unsigned int u32;
typedef unsigned long long u64;

static u64 dbits(double d) {
  u64 u;
  memcpy(&u, &d, 8);
  return u;
}

static double bitsd(u64 u) {
  double d;
  memcpy(&d, &u, 8);
  return d;
}

#define EXP(b) ((int)((b) >> 52) & 0x7FF)
#define FRAC(b) ((b) & 0xFFFFFFFFFFFFFULL)
#define SIGN(b) ((b) >> 63)

static const double inf_ = 1.0 / 0.0;

int __mycpu_signbit(double x) { return SIGN(dbits(x)); }
int __mycpu_isinf(double x) { return (dbits(x) << 1) == 0xFFE0000000000000ULL; }
int __mycpu_isnan(double x) { return x != x; }
int __mycpu_isfinite(double x) { return EXP(dbits(x)) != 0x7FF; }

double fabs(double x) { return bitsd(dbits(x) & ~(1ULL << 63)); }

double copysign(double x, double y) {
  return bitsd((dbits(x) & ~(1ULL << 63)) | (dbits(y) & (1ULL << 63)));
}

// ---- 切り捨て・切り上げ（ビットを直接いじる） ----

double trunc(double x) {
  u64 b = dbits(x);
  int e = EXP(b) - 1023;
  if (e >= 52)
    return x;                          // もう整数（か inf・NaN）
  if (e < 0)
    return bitsd(b & (1ULL << 63));    // ±0
  return bitsd(b & ~((1ULL << (52 - e)) - 1));
}

double floor(double x) {
  double t = trunc(x);
  return t > x ? t - 1.0 : t;
}

double ceil(double x) {
  double t = trunc(x);
  return t < x ? t + 1.0 : t;
}

double round(double x) {
  double t = trunc(x);
  double d = x - t;                    // 正確（|d| < 1）
  if (d >= 0.5)
    return t + 1.0;
  if (d <= -0.5)
    return t - 1.0;
  return t;
}

double nearbyint(double x) {           // 最近接偶数
  double r = round(x);
  if (fabs(x - trunc(x)) == 0.5)
    r = 2.0 * round(x / 2.0);
  return r;
}

double rint(double x) { return nearbyint(x); }
long lround(double x) { return (long)round(x); }
long lrint(double x) { return (long)nearbyint(x); }

double modf(double x, double *ip) {
  double t = trunc(x);
  *ip = t;
  if (__mycpu_isinf(x))
    return copysign(0.0, x);
  return copysign(x - t, x);
}

// x × 2^n（1 回だけ丸める）
double ldexp(double x, int n) {
  u64 b = dbits(x);
  int e = EXP(b);
  if (e == 0x7FF || (b << 1) == 0)
    return x;
  if (e == 0) {                        // 非正規化数：正規化してから
    x *= 0x1p54;
    b = dbits(x);
    e = EXP(b) - 54;
  }
  if (n > 5000) n = 5000;
  if (n < -5000) n = -5000;
  int ne = e + n;
  if (ne >= 0x7FF)
    return copysign(inf_, x);
  if (ne >= 1)
    return bitsd((b & ~(0x7FFULL << 52)) | ((u64)ne << 52));
  if (ne < -60)
    return copysign(0.0, x);
  // 結果は非正規化数：指数を 1000 上げた値に 2^-1000 を掛ける（ここで 1 回だけ丸まる）
  return bitsd((b & ~(0x7FFULL << 52)) | ((u64)(ne + 1000) << 52)) * 0x1p-1000;
}

double scalbn(double x, int n) { return ldexp(x, n); }

double frexp(double x, int *ep) {
  u64 b = dbits(x);
  int e = EXP(b);
  *ep = 0;
  if (e == 0x7FF || (b << 1) == 0)
    return x;
  if (e == 0) {
    x *= 0x1p54;
    b = dbits(x);
    e = EXP(b);
    *ep = -54;
  }
  *ep += e - 1022;
  return bitsd((b & ~(0x7FFULL << 52)) | (1022ULL << 52));
}

// ---- sqrt：整数の平方根（1 bit ずつ）。正しく丸める ----

double sqrt(double x) {
  u64 b = dbits(x);
  if (x != x || (b << 1) == 0)
    return x;                          // NaN・±0
  if (SIGN(b))
    return 0.0 / 0.0;
  int e = EXP(b);
  if (e == 0x7FF)
    return x;
  u64 m = FRAC(b);
  if (e == 0) {                        // 非正規化数を正規化
    e = 1;
    while (!(m >> 52)) {
      m <<= 1;
      e--;
    }
  } else {
    m |= 1ULL << 52;
  }
  int E = e - 1023;                    // x = m × 2^(E − 52)、m は 2^52〜2^53
  if (E & 1) {
    m <<= 1;
    E--;
  }
  // M = m × 2^54（108 bit：hi・lo）の平方根の整数部 r（54 bit）
  u64 hi = m >> 10, lo = m << 54;
  u64 r = 0, rem = 0;
  for (int i = 53; i >= 0; i--) {
    int s = 2 * i;
    u64 two = s >= 64 ? (hi >> (s - 64)) & 3 : (lo >> s) & 3;
    rem = (rem << 2) | two;
    u64 t = (r << 2) | 1;
    if (rem >= t) {
      rem -= t;
      r = (r << 1) | 1;
    } else {
      r <<= 1;
    }
  }
  // r は 2^53〜2^54。最後の 1 bit で丸める（ちょうど真ん中にはならない）
  u64 mant = r >> 1;
  if ((r & 1) && (rem || (mant & 1)))
    mant++;
  int be = E / 2 + 1023;
  if (mant >> 53) {
    mant >>= 1;
    be++;
  }
  return bitsd(((u64)be << 52) | (mant & 0xFFFFFFFFFFFFFULL));
}

// ---- fmod：余りは正確に求まる（1 bit ずつ引き算） ----

double fmod(double x, double y) {
  u64 bx = dbits(x), by = dbits(y);
  int ex = EXP(bx), ey = EXP(by);
  if (x != x || y != y || ex == 0x7FF || (by << 1) == 0)
    return (x * y) / (x * y);          // NaN
  if (ey == 0x7FF)
    return x;
  if ((bx << 1) < (by << 1))
    return x;
  u64 mx = FRAC(bx), my = FRAC(by);
  if (ex) mx |= 1ULL << 52; else { ex = 1; while (!(mx >> 52)) { mx <<= 1; ex--; } }
  if (ey) my |= 1ULL << 52; else { ey = 1; while (!(my >> 52)) { my <<= 1; ey--; } }
  for (; ex > ey; ex--) {
    if (mx >= my)
      mx -= my;
    mx <<= 1;
  }
  if (mx >= my)
    mx -= my;
  if (!mx)
    return copysign(0.0, x);
  while (!(mx >> 52)) {
    mx <<= 1;
    ey--;
  }
  // 値 = mx × 2^(ey − 1075)
  double r;
  if (ey >= 1)
    r = bitsd(((u64)ey << 52) | (mx & 0xFFFFFFFFFFFFFULL));
  else
    r = ldexp(bitsd((1023ULL << 52) | (mx & 0xFFFFFFFFFFFFFULL)), ey - 1023);
  return copysign(r, x);
}

double remainder(double x, double y) {
  double r = fmod(x, y);
  double ay = fabs(y), ar = fabs(r);
  if (ar > ay / 2 || (ar == ay / 2 && fmod(fabs((x - r) / y), 2.0) == 1.0))
    r = r > 0 ? r - ay : r + ay;
  return r;
}

// ---- double-double（2 つの double の和で 106 bit ほど）：log・pow・三角関数の途中で使う ----

// a + b = s + e（ちょうど）
static void two_sum(double a, double b, double *s, double *e) {
  double t = a + b, bb = t - a;
  *s = t;
  *e = (a - (t - bb)) + (b - bb);
}

// a × b = p + e（ちょうど。Dekker の方法：26 bit ずつに分けて掛ける。|a|・|b| < 2^995）
static void two_prod(double a, double b, double *p, double *e) {
  double c = 134217729.0 * a, ah = c - (c - a), al = a - ah;
  c = 134217729.0 * b;
  double bh = c - (c - b), bl = b - bh;
  double t = a * b;
  *p = t;
  *e = ((ah * bh - t) + ah * bl + al * bh) + al * bl;
}

// (ah + al) × (bh + bl)
static void dd_mul(double ah, double al, double bh, double bl, double *h, double *l) {
  double p, e;
  two_prod(ah, bh, &p, &e);
  e += ah * bl + al * bh;
  two_sum(p, e, h, l);
}

// ---- exp・log ----

static const double ln2_hi = 6.93147180369123816490e-01, ln2_lo = 1.90821492927058770002e-10;
static const double inv_ln2 = 1.44269504088896338700e+00;

double exp(double x) {
  if (x != x)
    return x;
  if (x > 709.782712893384)
    return inf_;
  if (x < -745.1332191019412)
    return 0.0;
  if (fabs(x) < 0x1p-28)
    return 1.0 + x;
  // x = k ln2 + r（|r| ≦ ln2 / 2）
  double kf = x * inv_ln2;
  int k = (int)(kf < 0 ? kf - 0.5 : kf + 0.5);
  double hi = x - k * ln2_hi, lo = k * ln2_lo;
  double r = hi - lo;
  double t = r * r;
  double c = r - t * (1.66666666666666019037e-01 + t * (-2.77777777770155933842e-03 + t * (6.61375632143793436117e-05 +
             t * (-1.65339022054652515390e-06 + t * 4.13813679705723846039e-08))));
  double y = 1.0 - ((lo - (r * c) / (2.0 - c)) - hi);
  return ldexp(y, k);
}

// log(x)（x は有限の正の数）を hi + lo で
static void log_dd(double x, double *hi, double *lo) {
  int k;
  double m = frexp(x, &k);
  if (m < 0.70710678118654752440) {
    m *= 2.0;
    k--;
  }
  // log(m) = 2 atanh(s) = 2s + 2s³/3 + 2s⁵/5 + …、s = f / (2 + f)、f = m − 1（ちょうど）
  double f = m - 1.0, dh, dl;
  two_sum(2.0, f, &dh, &dl);
  double sh = f / dh, p, pe;
  two_prod(sh, dh, &p, &pe);
  double sl = ((f - p) - pe - sh * dl) / dh;
  double z = sh * sh;
  double tail = 2.0 * sh * z * (1.0 / 3 + z * (1.0 / 5 + z * (1.0 / 7 + z * (1.0 / 9 + z * (1.0 / 11 + z * (1.0 / 13 +
                z * (1.0 / 15 + z * (1.0 / 17 + z * (1.0 / 19 + z * (1.0 / 21 + z * (1.0 / 23)))))))))));
  // k ln2 + 2sh + (2sl + tail)
  double a, ae;
  two_sum(k * ln2_hi, 2.0 * sh, &a, &ae);
  two_sum(a, ae + (k * ln2_lo + (2.0 * sl + tail)), hi, lo);
}

// log の前に：NaN・負・0・inf なら 1 を返して *r に答え
static int log_special(double x, double *r) {
  if (x != x)
    *r = x;
  else if (x < 0)
    *r = 0.0 / 0.0;
  else if (x == 0)
    *r = -inf_;
  else if (__mycpu_isinf(x))
    *r = x;
  else
    return 0;
  return 1;
}

double log(double x) {
  double r, h, l;
  if (log_special(x, &r))
    return r;
  log_dd(x, &h, &l);
  return h + l;
}

// log(x) × (c_hi + c_lo)
static double log_times(double x, double ch, double cl) {
  double r, h, l;
  if (log_special(x, &r))
    return r;
  log_dd(x, &h, &l);
  dd_mul(h, l, ch, cl, &h, &l);
  return h + l;
}

double log10(double x) { return log_times(x, 0.4342944819032518, 1.098319650216765e-17); }

double log2(double x) {
  int k;
  double m = frexp(x, &k);
  if (m == 0.5 && x > 0 && __mycpu_isfinite(x))
    return k - 1;                      // 2 の累乗はちょうど
  return log_times(x, 1.4426950408889634, 2.0355273740931033e-17);
}

double exp2(double x) {
  if (x == trunc(x) && fabs(x) < 2000)
    return ldexp(1.0, (int)x);
  // 2^x = e^(x ln2)：x ln2 を double-double で
  double h, l;
  dd_mul(x, 0, 0.6931471805599453, 2.3190468138462996e-17, &h, &l);
  double r = exp(h);
  return r + r * l;
}

// e^x − 1（0 の近くでも桁落ちしない）。|x| < 0.5 は テイラー展開（ホーナー法）
double expm1(double x) {
  if (fabs(x) < 0.5) {
    static const double c[] = {0.5, 0.16666666666666666, 0.041666666666666664, 0.008333333333333333,
                               0.001388888888888889, 0.0001984126984126984, 2.48015873015873e-05,
                               2.7557319223985893e-06, 2.755731922398589e-07, 2.505210838544172e-08,
                               2.08767569878681e-09, 1.6059043836821613e-10, 1.1470745597729725e-11,
                               7.647163731819816e-13, 4.779477332387385e-14, 2.8114572543455206e-15,
                               1.5619206968586225e-16, 8.22063524662433e-18};
    double t = c[17];
    for (int i = 16; i >= 0; i--)
      t = c[i] + x * t;
    return x + x * x * t;
  }
  return exp(x) - 1.0;
}

// log(1 + x)：1 + x = u + c（c は丸めで落ちた分）、log(u + c) ≒ log(u) + c / u
double log1p(double x) {
  if (x == 0 || __mycpu_isinf(x))
    return x;
  if (x < -1)
    return 0.0 / 0.0;
  if (x == -1)
    return -inf_;
  if (x != x)
    return x;
  double u, c, h, l;
  two_sum(1.0, x, &u, &c);
  log_dd(u, &h, &l);
  return h + (l + c / u);
}

// x の y 乗。y が小さい整数なら double-double で掛け算をくり返す。ほかは exp(y log|x|) を double-double で
double pow(double x, double y) {
  if (y == 0)
    return 1.0;
  if (x == 1.0)
    return 1.0;
  if (x != x || y != y)
    return x + y;
  int yint = y == trunc(y), yodd = yint && fabs(y) < 0x1p53 && fmod(y, 2.0) != 0;
  double ax = fabs(x);
  if (__mycpu_isinf(y)) {
    if (ax == 1.0)
      return 1.0;
    return (ax > 1.0) == (y > 0) ? inf_ : 0.0;
  }
  if (x == 0) {
    if (y < 0)
      return yodd ? copysign(inf_, x) : inf_;
    return yodd ? x : 0.0;
  }
  if (__mycpu_isinf(x)) {
    if (x < 0)
      return y < 0 ? (yodd ? -0.0 : 0.0) : (yodd ? -inf_ : inf_);
    return y < 0 ? 0.0 : inf_;
  }
  if (x < 0 && !yint)
    return 0.0 / 0.0;
  double sign = x < 0 && yodd ? -1.0 : 1.0;
  if (y == 0.5)
    return sqrt(ax);                   // 正しく丸まる（x < 0 はもう NaN、−0・−inf も上で済んでいる）

  if (yint && fabs(y) <= 64) {
    int n = (int)fabs(y), ok = 1;
    double rh = 1.0, rl = 0.0, ph = ax, pl = 0.0;
    while (n && ok) {
      if (n & 1)
        dd_mul(rh, rl, ph, pl, &rh, &rl);
      n >>= 1;
      if (n)
        dd_mul(ph, pl, ph, pl, &ph, &pl);
      // 大きすぎ・小さすぎると two_prod が使えない（あふれる・桁が足りない）
      ok = fabs(rh) < 0x1p990 && fabs(rh) > 0x1p-960 && fabs(ph) < 0x1p990 && fabs(ph) > 0x1p-960;
    }
    if (ok) {
      if (y > 0)
        return sign * (rh + rl);
      double q = 1.0 / rh, p, pe;      // 1 / (rh + rl)
      two_prod(q, rh, &p, &pe);
      double ql = ((1.0 - p) - pe - q * rl) / rh;
      return sign * (q + ql);
    }
  }

  if (fabs(y) > 0x1p64)                 // |log x| ≧ 2^-53 なので、かならずあふれる
    return (ax > 1.0) == (y > 0) ? sign * inf_ : sign * 0.0;
  double lh, ll, th, tl;
  log_dd(ax, &lh, &ll);
  two_prod(y, lh, &th, &tl);
  tl += y * ll;
  double t = th + tl;
  if (t > 709.8)
    return sign * inf_;
  if (t < -745.2)
    return sign * 0.0;
  tl -= t - th;                        // t + tl ≒ y log|x|
  double r = exp(t);
  return sign * (r + r * tl);
}

double cbrt(double x) {
  if (x == 0 || x != x || __mycpu_isinf(x))
    return x;
  double a = fabs(x);
  int k;
  double m = frexp(a, &k);             // a = m × 2^k
  int q = k / 3, rr = k % 3;
  if (rr < 0) { rr += 3; q--; }
  m = ldexp(m, rr);                    // 0.5〜4
  double y = 0.7 + 0.3 * m;            // ニュートン法
  for (int i = 0; i < 8; i++)
    y = y - (y * y * y - m) / (3.0 * y * y);
  y = ldexp(y, q);
  return x < 0 ? -y : y;
}

double hypot(double x, double y) {
  x = fabs(x);
  y = fabs(y);
  if (__mycpu_isinf(x) || __mycpu_isinf(y))
    return inf_;
  if (x != x || y != y)
    return x + y;
  if (x < y) {
    double t = x; x = y; y = t;
  }
  if (x == 0)
    return 0.0;
  double r = y / x;
  return x * sqrt(1.0 + r * r);
}

// ---- 三角関数 ----

// π/2 を 3 つに分けたもの（はじめの 2 つは 33 bit。n < 2^20 なら n × それ がちょうど計算できる）
static const double pio2_1 = 1.57079632673412561417e+00, pio2_2 = 6.07710050630396597660e-11,
                    pio2_3 = 2.02226624871116645580e-21;

// x = n π/2 + (r + rl)（|r| ≦ π/4 ほど）。n の下 2 bit を返す。|x| が 2^20 × π/2 くらいまで正確
static int rem_pio2(double x, double *r, double *rl) {
  if (fabs(x) <= 0.78539816339744830962) {
    *r = x;
    *rl = 0;
    return 0;
  }
  double nf = round(x * 6.36619772367581382433e-01);
  double r0 = x - nf * pio2_1;         // ちょうど
  double w = nf * pio2_2;              // ちょうど
  double t = r0 - w, e = (r0 - t) - w; // t + e = r0 − w（ちょうど）
  double lo = e - nf * pio2_3;
  *r = t + lo;
  *rl = (t - *r) + lo;
  return (int)fmod(nf, 4.0) & 3;
}

// sin(x + y)、cos(x + y)（|x| ≦ π/4、y は x の下の桁。係数は fdlibm）
static double k_sin(double x, double y) {
  double z = x * x, v = z * x;
  double r = 8.33333333332248946124e-03 + z * (-1.98412698298579493134e-04 + z * (2.75573137070700676789e-06 +
             z * (-2.50507602534068634195e-08 + z * 1.58969099521155010221e-10)));
  return x - ((z * (0.5 * y - v * r) - y) - v * -1.66666666666666324348e-01);
}

static double k_cos(double x, double y) {
  double z = x * x;
  double r = z * (4.16666666666666019037e-02 + z * (-1.38888888888741095749e-03 + z * (2.48015872894767294178e-05 +
             z * (-2.75573143513906633035e-07 + z * (2.08757232129817482790e-09 + z * -1.13596475577881948265e-11)))));
  double hz = 0.5 * z, w = 1.0 - hz;
  return w + (((1.0 - w) - hz) + (z * r - x * y));
}

double sin(double x) {
  if (x != x || __mycpu_isinf(x))
    return x - x;
  double r, rl;
  switch (rem_pio2(x, &r, &rl)) {
  case 0: return k_sin(r, rl);
  case 1: return k_cos(r, rl);
  case 2: return -k_sin(r, rl);
  default: return -k_cos(r, rl);
  }
}

double cos(double x) {
  if (x != x || __mycpu_isinf(x))
    return x - x;
  double r, rl;
  switch (rem_pio2(x, &r, &rl)) {
  case 0: return k_cos(r, rl);
  case 1: return -k_sin(r, rl);
  case 2: return -k_cos(r, rl);
  default: return k_sin(r, rl);
  }
}

double tan(double x) {
  if (x != x || __mycpu_isinf(x))
    return x - x;
  double r, rl;
  int n = rem_pio2(x, &r, &rl);
  double s = k_sin(r, rl), c = k_cos(r, rl);
  return n & 1 ? -c / s : s / c;
}

static const double atanhi[] = {4.63647609000806093515e-01, 7.85398163397448278999e-01, 9.82793723247329054082e-01,
                                1.57079632679489655800e+00};
static const double atanlo[] = {2.26987774529616870924e-17, 3.06161699786838301793e-17, 1.39033110312309984516e-17,
                                6.12323399573676603587e-17};
static const double aT[] = {3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01,
                            -1.11111104054623557880e-01, 9.09088713343650656196e-02, -7.69187620504482999495e-02,
                            6.66107313738753120669e-02, -5.83357013379057348645e-02, 4.97687799461593236017e-02,
                            -3.65315727442169155270e-02, 1.62858201153657823623e-02};

double atan(double x) {
  if (x != x)
    return x;
  double ax = fabs(x);
  int id;
  if (ax >= 0x1p66)
    return copysign(atanhi[3] + atanlo[3], x);
  if (ax < 0.4375) {
    if (ax < 0x1p-29)
      return x;
    id = -1;
  } else if (ax < 1.1875) {
    if (ax < 0.6875) {
      id = 0;
      ax = (2.0 * ax - 1.0) / (2.0 + ax);
    } else {
      id = 1;
      ax = (ax - 1.0) / (ax + 1.0);
    }
  } else if (ax < 2.4375) {
    id = 2;
    ax = (ax - 1.5) / (1.0 + 1.5 * ax);
  } else {
    id = 3;
    ax = -1.0 / ax;
  }
  double z = ax * ax, w = z * z;
  double s1 = z * (aT[0] + w * (aT[2] + w * (aT[4] + w * (aT[6] + w * (aT[8] + w * aT[10])))));
  double s2 = w * (aT[1] + w * (aT[3] + w * (aT[5] + w * (aT[7] + w * aT[9]))));
  if (id < 0)
    return x - x * (s1 + s2);
  double r = atanhi[id] - ((ax * (s1 + s2) - atanlo[id]) - ax);
  return copysign(r, x);
}

static const double pi = 3.14159265358979311600e+00, pi_lo = 1.2246467991473531772e-16;

double atan2(double y, double x) {
  if (x != x || y != y)
    return x + y;
  if (x == 1.0)
    return atan(y);
  int ys = __mycpu_signbit(y), xs = __mycpu_signbit(x);
  if (y == 0) {
    if (!xs)
      return y;                        // ±0
    return ys ? -pi - pi_lo : pi + pi_lo;
  }
  if (x == 0)
    return ys ? -atanhi[3] - atanlo[3] : atanhi[3] + atanlo[3];
  if (__mycpu_isinf(x)) {
    if (__mycpu_isinf(y)) {
      double r = xs ? 3.0 * 7.85398163397448278999e-01 : 7.85398163397448278999e-01;
      return ys ? -r : r;
    }
    double r = xs ? pi : 0.0;
    return ys ? -r : r;
  }
  if (__mycpu_isinf(y))
    return ys ? -atanhi[3] - atanlo[3] : atanhi[3] + atanlo[3];
  double z = atan(fabs(y / x));
  if (xs)
    z = pi - (z - pi_lo);
  return ys ? -z : z;
}

double asin(double x) {
  if (fabs(x) > 1.0)
    return 0.0 / 0.0;
  if (fabs(x) == 1.0)
    return copysign(atanhi[3] + atanlo[3], x);
  return atan2(x, sqrt((1.0 - x) * (1.0 + x)));
}

double acos(double x) {
  if (fabs(x) > 1.0)
    return 0.0 / 0.0;
  return atan2(sqrt((1.0 - x) * (1.0 + x)), x);
}

double sinh(double x) {
  double t = expm1(fabs(x));
  if (__mycpu_isinf(t))
    return copysign(t, x);
  double r = 0.5 * (t + t / (t + 1.0));
  return copysign(r, x);
}

double cosh(double x) {
  double e = exp(fabs(x));
  if (__mycpu_isinf(e))
    return e;
  return 0.5 * (e + 1.0 / e);
}

double tanh(double x) {
  if (fabs(x) > 22)
    return copysign(1.0, x);
  double t = expm1(2.0 * fabs(x));
  return copysign(t / (t + 2.0), x);
}

double asinh(double x) {
  double a = fabs(x);
  double r = a > 0x1p28 ? log(a) + ln2_hi + ln2_lo : log1p(a + a * a / (1.0 + sqrt(1.0 + a * a)));
  return copysign(r, x);
}

double acosh(double x) {
  if (x < 1.0)
    return 0.0 / 0.0;
  if (x > 0x1p28)
    return log(x) + ln2_hi + ln2_lo;
  double t = x - 1.0;
  return log1p(t + sqrt(2.0 * t + t * t));
}

double atanh(double x) {
  double a = fabs(x);
  if (a > 1.0)
    return 0.0 / 0.0;
  return copysign(0.5 * log1p(2.0 * a / (1.0 - a)), x);
}

double fmax(double x, double y) { return x != x ? y : y != y ? x : x > y ? x : y; }
double fmin(double x, double y) { return x != x ? y : y != y ? x : x < y ? x : y; }
double fdim(double x, double y) { return x > y ? x - y : 0.0; }
double fma(double x, double y, double z) { return x * y + z; }   // 1 回では丸めない（簡単な版）

// ---- float の版：double で計算して丸める ----
float fabsf(float x) { return fabs(x); }
float sqrtf(float x) { return sqrt(x); }       // double で正しく丸めてから float へ：2 回丸めても同じ
float floorf(float x) { return floor(x); }
float ceilf(float x) { return ceil(x); }
float truncf(float x) { return trunc(x); }
float roundf(float x) { return round(x); }
float fmodf(float x, float y) { return fmod(x, y); }
float expf(float x) { return exp(x); }
float logf(float x) { return log(x); }
float log10f(float x) { return log10(x); }
float log2f(float x) { return log2(x); }
float powf(float x, float y) { return pow(x, y); }
float sinf(float x) { return sin(x); }
float cosf(float x) { return cos(x); }
float tanf(float x) { return tan(x); }
float atanf(float x) { return atan(x); }
float atan2f(float y, float x) { return atan2(y, x); }
float asinf(float x) { return asin(x); }
float acosf(float x) { return acos(x); }
float sinhf(float x) { return sinh(x); }
float coshf(float x) { return cosh(x); }
float tanhf(float x) { return tanh(x); }
float hypotf(float x, float y) { return hypot(x, y); }
float cbrtf(float x) { return cbrt(x); }
float ldexpf(float x, int n) { return ldexp(x, n); }
float frexpf(float x, int *e) { return frexp(x, e); }
float copysignf(float x, float y) { return copysign(x, y); }
float fmaxf(float x, float y) { return fmax(x, y); }
float fminf(float x, float y) { return fmin(x, y); }
