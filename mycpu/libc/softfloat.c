// 浮動小数点（IEEE 754）をソフトウェアで計算する。この CPU には浮動小数点の命令がないので、
// cc/codegen.c が float・double の計算や変換のたびにここの関数を呼ぶ。整数の演算だけで書いてある。
//   double：足す・引く・掛ける・割る・比べる・整数との変換。丸めは最近接偶数。無限大・NaN・非正規化数も
//   float：double に広げて計算し、float に丸める（double の精度は float の 2 倍 + 2 bit 以上あるので、
//          これで +・−・×・÷ とも正しく丸めた結果と同じになる）
// 値はビット列（float は unsigned、double は unsigned long long）で受け渡す。
// PC の gcc でもそのままコンパイルでき、test/floattest.c で PC の計算とビット単位で比べている。
// MyCPU では、よく使うもの（double の足す・引く・掛ける・割る・比べる・int との変換、float ↔ double、
// float の比べる・int との変換）は libc/softfloat.s のアセンブリを使い、ここの C 版は入れない
// （SOFTFLOAT_REF を定義すると入れる。test/fasmtest.c が両方を比べる）
typedef unsigned u32;
typedef unsigned long long u64;
typedef long long i64;

#define DSIGN(x) ((x) >> 63)
#define DEXP(x) ((int)((x) >> 52) & 0x7ff)
#define DFRAC(x) ((x) & 0x000FFFFFFFFFFFFFULL)
#define DNAN 0x7FF8000000000000ULL
#define DINF 0x7FF0000000000000ULL
// アセンブリ版のある関数の C 版を入れるか
#if !defined(__MYCPU__) || defined(SOFTFLOAT_REF)
#define C_VERSION 1
#else
#define C_VERSION 0
#endif
u64 __adddf3(u64 a, u64 b);
u64 __subdf3(u64 a, u64 b);
u64 __muldf3(u64 a, u64 b);
u64 __divdf3(u64 a, u64 b);
int __mycpu_dcmp(u64 a, u64 b);
u64 __floatsidf(int v);
u64 __floatunsidf(u32 v);
int __fixdfsi(u64 a);
u32 __fixunsdfsi(u64 a);
u64 __extendsfdf2(u32 f);
u32 __truncdfsf2(u64 a);

static int d_isnan(u64 x) { return DEXP(x) == 0x7ff && DFRAC(x) != 0; }
static int d_isinf(u64 x) { return DEXP(x) == 0x7ff && DFRAC(x) == 0; }
static int d_iszero(u64 x) { return (x << 1) == 0; }

// 右へずらす。こぼれた bit があれば最下位を 1 に（丸めのため）
static u64 shr_sticky(u64 m, int n) {
  if (n <= 0)
    return m;
  if (n >= 64)
    return m != 0;
  return (m >> n) | ((m & ((1ULL << n) - 1)) != 0);
}

// 符号 s、値 = m × 2^(e − 1023 − 62) を double に丸める（m は 0 以外。どの bit が先頭でもよい）
static u64 pack_d(int s, int e, u64 m) {
  u64 sign = (u64)s << 63;
  if (m == 0)
    return sign;
  while (m < (1ULL << 62)) {
    m <<= 1;
    e--;
  }
  while (m >= (1ULL << 63)) {
    m = shr_sticky(m, 1);
    e++;
  }
  if (e >= 0x7ff)
    return sign | DINF;
  int denorm = e <= 0;
  if (denorm) {
    m = shr_sticky(m, 1 - e);
    e = 0;
  }
  u64 r = m & 0x3ff;                    // 下の 10 bit で丸める
  m >>= 10;
  if (r > 0x200 || (r == 0x200 && (m & 1)))
    m++;
  // 正規化数は m の bit 52（暗黙の 1）が指数に 1 足されるので、指数は e − 1 で詰める
  if (denorm)
    return sign | m;
  return sign | (((u64)(e - 1) << 52) + m);
}

// double を 符号・指数・仮数（暗黙の 1 を bit 52 に置き、非正規化数は正規化する）に分ける
static u64 unpack_d(u64 x, int *s, int *e) {
  *s = DSIGN(x);
  *e = DEXP(x);
  u64 m = DFRAC(x);
  if (*e == 0) {
    *e = 1;
    while (m && m < (1ULL << 52)) {
      m <<= 1;
      (*e)--;
    }
  } else {
    m |= 1ULL << 52;
  }
  return m;
}

#if C_VERSION
u64 __adddf3(u64 a, u64 b) {
  if (d_isnan(a) || d_isnan(b))
    return DNAN;
  if (d_isinf(a)) {
    if (d_isinf(b) && DSIGN(a) != DSIGN(b))
      return DNAN;
    return a;
  }
  if (d_isinf(b))
    return b;
  if (d_iszero(a)) {
    if (d_iszero(b))
      return a & b;                     // −0 + −0 = −0、ほかは +0
    return b;
  }
  if (d_iszero(b))
    return a;

  int sa, ea, sb, eb;
  u64 ma = unpack_d(a, &sa, &ea) << 10;
  u64 mb = unpack_d(b, &sb, &eb) << 10;
  if (ea < eb || (ea == eb && ma < mb)) {   // a の方を大きく
    u64 t = ma; ma = mb; mb = t;
    int ti = ea; ea = eb; eb = ti;
    ti = sa; sa = sb; sb = ti;
  }
  mb = shr_sticky(mb, ea - eb);
  if (sa == sb)
    return pack_d(sa, ea, ma + mb);
  u64 m = ma - mb;
  if (m == 0)
    return 0;                           // x − x = +0
  return pack_d(sa, ea, m);
}

u64 __subdf3(u64 a, u64 b) {
  return __adddf3(a, b ^ (1ULL << 63));
}

// 64bit × 64bit → 128bit（上位を *hi、下位を戻り値）
static u64 mul64(u64 a, u64 b, u64 *hi) {
  u64 a0 = a & 0xffffffff, a1 = a >> 32, b0 = b & 0xffffffff, b1 = b >> 32;
  u64 p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  u64 mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff);
  *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
  return (mid << 32) | (p00 & 0xffffffff);
}

u64 __muldf3(u64 a, u64 b) {
  int s = DSIGN(a) ^ DSIGN(b);
  if (d_isnan(a) || d_isnan(b))
    return DNAN;
  if (d_isinf(a) || d_isinf(b)) {
    if (d_iszero(a) || d_iszero(b))
      return DNAN;
    return ((u64)s << 63) | DINF;
  }
  if (d_iszero(a) || d_iszero(b))
    return (u64)s << 63;
  int sa, ea, sb, eb;
  u64 ma = unpack_d(a, &sa, &ea), mb = unpack_d(b, &sb, &eb);
  u64 hi, lo = mul64(ma, mb, &hi);     // 106bit（先頭は bit 104 か 105）
  // 42 bit 右へ（こぼれた bit は最下位に）→ 先頭は bit 62 か 63
  u64 m = (hi << 22) | (lo >> 42) | ((lo & ((1ULL << 42) - 1)) != 0);
  return pack_d(s, ea + eb - 1023, m);
}

u64 __divdf3(u64 a, u64 b) {
  int s = DSIGN(a) ^ DSIGN(b);
  if (d_isnan(a) || d_isnan(b))
    return DNAN;
  if (d_isinf(a)) {
    if (d_isinf(b))
      return DNAN;
    return ((u64)s << 63) | DINF;
  }
  if (d_isinf(b))
    return (u64)s << 63;
  if (d_iszero(b)) {
    if (d_iszero(a))
      return DNAN;
    return ((u64)s << 63) | DINF;
  }
  if (d_iszero(a))
    return (u64)s << 63;
  int sa, ea, sb, eb;
  u64 ma = unpack_d(a, &sa, &ea), mb = unpack_d(b, &sb, &eb);
  // 筆算で 64 bit の商：q = ma ÷ mb × 2^63（先頭は bit 62 か 63）。余りがあれば最下位を 1 に
  u64 q = 0, r = ma;
  for (int i = 0; i < 64; i++) {
    q <<= 1;
    if (r >= mb) {
      r -= mb;
      q |= 1;
    }
    r <<= 1;
  }
  return pack_d(s, ea - eb + 1022, q | (r != 0));
}

// 比べる：−1 = a < b、0 = 等しい、1 = a > b、2 = どちらかが NaN
int __mycpu_dcmp(u64 a, u64 b) {
  if (d_isnan(a) || d_isnan(b))
    return 2;
  if (d_iszero(a) && d_iszero(b))
    return 0;
  if (a == b)
    return 0;
  int sa = DSIGN(a), sb = DSIGN(b);
  if (sa != sb)
    return sa ? -1 : 1;
  int less = a < b;                     // 同じ符号なら、ビット列の大小（負なら逆）
  if (sa)
    less = !less;
  return less ? -1 : 1;
}

#endif

// ---- 整数 ↔ double ----
u64 __floatdidf(i64 v) {
  if (v == 0)
    return 0;
  int s = v < 0;
  u64 m = s ? -(u64)v : (u64)v;
  return pack_d(s, 1023 + 62, m);
}

u64 __floatundidf(u64 v) {
  if (v == 0)
    return 0;
  return pack_d(0, 1023 + 62, v);
}

#if C_VERSION
u64 __floatsidf(int v) { return __floatdidf(v); }
u64 __floatunsidf(u32 v) { return __floatundidf(v); }

#endif

// 0 の方へ切り捨てて整数に（入りきらなければ、いちばん大きい・小さい値）
i64 __fixdfdi(u64 a) {
  if (d_isnan(a))
    return 0;
  int s, e;
  u64 m = unpack_d(a, &s, &e);         // 値 = m × 2^(e − 1075)
  if (e < 1023)
    return 0;
  int sh = e - 1075;
  if (sh >= 11)
    return s ? (i64)(1ULL << 63) : (i64)((1ULL << 63) - 1);
  u64 v = sh >= 0 ? m << sh : m >> -sh;
  return s ? -(i64)v : (i64)v;
}

u64 __fixunsdfdi(u64 a) {
  if (d_isnan(a) || DSIGN(a))
    return 0;
  int s, e;
  u64 m = unpack_d(a, &s, &e);
  if (e < 1023)
    return 0;
  int sh = e - 1075;
  if (sh >= 12)
    return ~0ULL;
  return sh >= 0 ? m << sh : m >> -sh;
}

#if C_VERSION
int __fixdfsi(u64 a) {
  i64 v = __fixdfdi(a);
  if (v > 0x7fffffffLL)
    return 0x7fffffff;
  if (v < -0x80000000LL)
    return (int)0x80000000u;
  return (int)v;
}

u32 __fixunsdfsi(u64 a) {
  u64 v = __fixunsdfdi(a);
  return v > 0xffffffffULL ? 0xffffffffu : (u32)v;
}

#endif

// ---- float ↔ double ----
#if C_VERSION
u64 __extendsfdf2(u32 f) {
  u64 sign = (u64)(f >> 31) << 63;
  int e = (f >> 23) & 0xff;
  u64 m = f & 0x7fffff;
  if (e == 0xff)
    return sign | DINF | (m ? (1ULL << 51) | (m << 29) : 0);
  if (e == 0) {
    if (m == 0)
      return sign;
    e = 1;
    while (m < 0x800000) {              // 非正規化数は正規化する
      m <<= 1;
      e--;
    }
    m &= 0x7fffff;
  }
  return sign | ((u64)(e - 127 + 1023) << 52) | (m << 29);
}

u32 __truncdfsf2(u64 a) {
  u32 sign = (u32)(a >> 63) << 31;
  if (d_isnan(a))
    return 0x7fc00000;
  if (d_isinf(a))
    return sign | 0x7f800000;
  if (d_iszero(a))
    return sign;
  int s, e;
  u64 m = unpack_d(a, &s, &e) << 10;   // 値 = m × 2^(e − 1023 − 62)、先頭は bit 62
  int fe = e - 1023 + 127;
  if (fe >= 0xff)
    return sign | 0x7f800000;
  int denorm = fe <= 0;
  if (denorm) {
    m = shr_sticky(m, 1 - fe);
    fe = 0;
  }
  u64 r = m & ((1ULL << 39) - 1);       // 下の 39 bit で丸めて 24 bit に
  u32 f = m >> 39;
  if (r > (1ULL << 38) || (r == (1ULL << 38) && (f & 1)))
    f++;
  if (denorm)
    return sign | f;
  return sign | (((u32)(fe - 1) << 23) + f);
}
#endif

// ---- float（double に広げて計算し、丸めて戻す） ----
u32 __addsf3(u32 a, u32 b) { return __truncdfsf2(__adddf3(__extendsfdf2(a), __extendsfdf2(b))); }
u32 __subsf3(u32 a, u32 b) { return __truncdfsf2(__subdf3(__extendsfdf2(a), __extendsfdf2(b))); }
u32 __mulsf3(u32 a, u32 b) { return __truncdfsf2(__muldf3(__extendsfdf2(a), __extendsfdf2(b))); }
u32 __divsf3(u32 a, u32 b) { return __truncdfsf2(__divdf3(__extendsfdf2(a), __extendsfdf2(b))); }
#if C_VERSION
int __mycpu_fcmp(u32 a, u32 b) { return __mycpu_dcmp(__extendsfdf2(a), __extendsfdf2(b)); }
u32 __floatsisf(int v) { return __truncdfsf2(__floatsidf(v)); }
u32 __floatunsisf(u32 v) { return __truncdfsf2(__floatunsidf(v)); }
int __fixsfsi(u32 f) { return __fixdfsi(__extendsfdf2(f)); }
u32 __fixunssfsi(u32 f) { return __fixunsdfsi(__extendsfdf2(f)); }
#endif
i64 __fixsfdi(u32 f) { return __fixdfdi(__extendsfdf2(f)); }
u64 __fixunssfdi(u32 f) { return __fixunsdfdi(__extendsfdf2(f)); }

// long long → float は、double を通すと 2 回丸めることになるので、直接丸める
static u32 int_to_f(int s, u64 m) {
  if (m == 0)
    return 0;
  int e = 1023 + 62;
  while (m >= (1ULL << 63)) {
    m = shr_sticky(m, 1);
    e++;
  }
  while (m < (1ULL << 62)) {
    m <<= 1;
    e--;
  }
  // m の先頭は bit 62。double として切り詰めると丸めが 2 回になるので、float の丸めを直接
  u64 d = ((u64)s << 63) | ((u64)e << 52) | ((m >> 10) & 0x000FFFFFFFFFFFFFULL);
  u64 low = m & 0x3ff;
  if (low)
    d |= 1;                             // 落ちた bit は double の最下位へ（float の丸めには十分）
  return __truncdfsf2(d);
}

u32 __floatdisf(i64 v) { return v < 0 ? int_to_f(1, -(u64)v) : int_to_f(0, v); }
u32 __floatundisf(u64 v) { return int_to_f(0, v); }
