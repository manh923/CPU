// 浮動小数点と 10 進の文字列（printf の %f・%e・%g と strtod）。どちらも正しく丸める（IEEE 754 の最近接偶数）
//   double はビット列 m × 2^e。大きな整数（32bit の語の並び）で、ちょうどの 10 進の値を作ってから丸める
// 整数の計算だけなので、PC の gcc でもそのままビルドできる（test/fltiotest.c が glibc と比べる）
#include <stdlib.h>
#include <string.h>
#include <errno.h>

typedef unsigned int u32;
typedef unsigned long long u64;

#define NW 180                  // 大きな整数の語の数（5760bit。strtod の 800 桁 × 10^330 まで入る）

typedef struct {
  int n;                        // 使っている語の数（上の 0 の語は持たない）
  u32 w[NW];                    // 下の語から
} Big;

static void big_set(Big *a, u64 v) {
  a->n = 0;
  while (v) {
    a->w[a->n++] = (u32)v;
    v >>= 32;
  }
}

// a = a × m + c（m < 2^32）
static void big_muladd(Big *a, u32 m, u32 c) {
  u64 carry = c;
  for (int i = 0; i < a->n; i++) {
    u64 t = (u64)a->w[i] * m + carry;
    a->w[i] = (u32)t;
    carry = t >> 32;
  }
  if (carry && a->n < NW)
    a->w[a->n++] = (u32)carry;
}

static int big_bits(Big *a) {
  if (!a->n)
    return 0;
  int b = (a->n - 1) * 32;
  for (u32 t = a->w[a->n - 1]; t; t >>= 1)
    b++;
  return b;
}

static void big_shl(Big *a, int s) {
  int ws = s / 32, bs = s % 32;
  if (!a->n || s <= 0)
    return;
  int n = a->n + ws + 1;
  if (n > NW)
    n = NW;
  for (int i = n - 1; i >= 0; i--) {
    int j = i - ws;
    u32 hi = j >= 0 && j < a->n ? a->w[j] : 0;
    u32 lo = j - 1 >= 0 && j - 1 < a->n ? a->w[j - 1] : 0;
    a->w[i] = bs ? (hi << bs) | (lo >> (32 - bs)) : hi;
  }
  a->n = n;
  while (a->n && !a->w[a->n - 1])
    a->n--;
}

static void big_shr1(Big *a) {
  for (int i = 0; i < a->n; i++)
    a->w[i] = (a->w[i] >> 1) | (i + 1 < a->n ? a->w[i + 1] << 31 : 0);
  while (a->n && !a->w[a->n - 1])
    a->n--;
}

static int big_cmp(Big *a, Big *b) {
  if (a->n != b->n)
    return a->n < b->n ? -1 : 1;
  for (int i = a->n - 1; i >= 0; i--)
    if (a->w[i] != b->w[i])
      return a->w[i] < b->w[i] ? -1 : 1;
  return 0;
}

// a −= b（a ≧ b）
static void big_sub(Big *a, Big *b) {
  u32 borrow = 0;
  for (int i = 0; i < a->n; i++) {
    u32 bi = i < b->n ? b->w[i] : 0;
    u32 t = a->w[i] - bi - borrow;
    borrow = a->w[i] < bi || (a->w[i] == bi && borrow) ? 1 : 0;
    a->w[i] = t;
  }
  while (a->n && !a->w[a->n - 1])
    a->n--;
}

// a を 10000 で割って余りを返す（16bit ずつ割るので、32bit の割り算だけで済む）
static u32 big_div10000(Big *a) {
  u32 r = 0;
  for (int i = a->n - 1; i >= 0; i--) {
    u32 hi = (r << 16) | (a->w[i] >> 16);
    u32 qh = hi / 10000;
    r = hi % 10000;
    u32 lo = (r << 16) | (a->w[i] & 0xFFFF);
    u32 ql = lo / 10000;
    r = lo % 10000;
    a->w[i] = (qh << 16) | ql;
  }
  while (a->n && !a->w[a->n - 1])
    a->n--;
  return r;
}

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

// ---- double → 10 進 ----

static Big fbig;                // 小数部（frac_k bit の固定小数点）
static int frac_k;
static char fq[9];              // 小数部から出した数字の残り（9 桁ずつ出す）：fq[9 − fqn] 〜 fq[8]
static int fqn;

// x（有限、0 以上）のちょうどの 10 進：整数部の数字を buf に（0 なら 0 文字）、*nint にその桁数。
// 小数部は next_frac_digit で 1 桁ずつ出す
static int int_digits(u64 bits, char *buf) {
  fqn = 0;
  int be = (bits >> 52) & 0x7FF;
  u64 m = bits & 0xFFFFFFFFFFFFFULL;
  if (be)
    m |= 1ULL << 52;
  int e = (be ? be : 1) - 1075;          // x = m × 2^e

  Big ip;
  if (e >= 0) {
    big_set(&ip, m);
    big_shl(&ip, e);
    big_set(&fbig, 0);
    frac_k = 0;
  } else {
    int k = -e;
    big_set(&ip, k < 64 ? m >> k : 0);
    u64 f = k < 64 ? m & ((1ULL << k) - 1) : m;
    // 小数部を 32 の倍数の bit に揃える（×10 したときの桁上がりが、そのまま次の数字になる）
    int s = (32 - k % 32) % 32;
    frac_k = k + s;
    big_set(&fbig, f);
    big_shl(&fbig, s);
  }

  // 整数部を 4 桁ずつ（下から）
  char tmp[400];
  int n = 0;
  while (ip.n) {
    u32 r = big_div10000(&ip);
    for (int i = 0; i < 4; i++) {
      tmp[n++] = '0' + r % 10;
      r /= 10;
    }
  }
  while (n > 0 && tmp[n - 1] == '0')
    n--;
  for (int i = 0; i < n; i++)
    buf[i] = tmp[n - 1 - i];
  return n;
}

// 小数部の次の 1 桁。小数部に 10^9 を掛けて、はみ出た分（9 桁）をためておく
static int next_frac_digit(void) {
  if (!fqn) {
    if (!fbig.n)
      return 0;
    int nw = frac_k / 32;
    u64 carry = 0;
    for (int i = 0; i < nw; i++) {
      u64 t = (u64)(i < fbig.n ? fbig.w[i] : 0) * 1000000000 + carry;
      fbig.w[i] = (u32)t;
      carry = t >> 32;
    }
    fbig.n = nw;
    while (fbig.n && !fbig.w[fbig.n - 1])
      fbig.n--;
    u32 c = (u32)carry;
    for (int i = 8; i >= 0; i--) {
      fq[i] = c % 10;
      c /= 10;
    }
    fqn = 9;
  }
  return fq[9 - fqn--];
}

// まだ出していない小数部に 0 でない数字があるか
static int frac_rest(void) {
  for (int i = 9 - fqn; i < 9; i++)
    if (fq[i])
      return 1;
  return fbig.n != 0;
}

// d[0..len) を keep 桁に丸める（最近接偶数。sticky = d[len] より後ろに 0 でないものがある）。
// 繰り上がって桁が増えたら 1 を返す（d は keep + 1 桁になる）
static int round_digits(char *d, int len, int keep, int sticky) {
  if (keep >= len)
    return 0;
  int next = d[keep] - '0';
  for (int i = keep + 1; i < len; i++)
    if (d[i] != '0')
      sticky = 1;
  int odd = keep > 0 && (d[keep - 1] - '0') % 2;
  if (next > 5 || (next == 5 && (sticky || odd))) {
    int i = keep - 1;
    while (i >= 0 && d[i] == '9')
      d[i--] = '0';
    if (i >= 0) {
      d[i]++;
    } else {
      memmove(d + 1, d, keep);
      d[0] = '1';
      return 1;
    }
  }
  return 0;
}

#define DBUF 1500
#define MAXPREC 1000
static char dg[DBUF + 2];

// %f の数字：整数部（の桁数を返す。0 のときは整数部は「0」）と小数 prec 桁を dg に
static int gen_f(u64 bits, int prec) {
  int nint = int_digits(bits, dg), len = nint;
  while (len < nint + prec + 1)
    dg[len++] = '0' + next_frac_digit();
  return nint + round_digits(dg, len, nint + prec, frac_rest());
}

// %e の数字：最初の 0 でない数字から prec + 1 桁を dg に。10 の指数を返す
static int gen_e(u64 bits, int prec) {
  if (bits == 0) {
    memset(dg, '0', prec + 1);
    return 0;
  }
  int nint = int_digits(bits, dg), len = nint, exp10 = nint - 1;
  if (!nint) {
    int c;
    while ((c = next_frac_digit()) == 0)
      exp10--;
    dg[len++] = '0' + c;
  }
  while (len < prec + 2)
    dg[len++] = '0' + next_frac_digit();
  return exp10 + round_digits(dg, len, prec + 1, frac_rest());
}

// x（有限）を %f・%e・%g の形に（符号は除く）。out に入れて長さを返す。conv は f e g（大文字もよい）
int __mycpu_dtoa(double x, int conv, int prec, int alt, char *out) {
  int upper = conv >= 'A' && conv <= 'Z';
  conv |= 0x20;
  if (prec < 0)
    prec = 6;
  if (prec > MAXPREC)
    prec = MAXPREC;
  u64 bits = dbits(x) & ~(1ULL << 63);
  char *o = out;

  // %g：有効数字 P 桁で %e にしたときの指数で、%e か %f を選ぶ。# がなければ末尾の 0 を取る
  int strip = 0;
  if (conv == 'g') {
    int p = prec ? prec : 1;
    int exp10 = gen_e(bits, p - 1);
    if (exp10 < -4 || exp10 >= p) {
      conv = 'e';
      prec = p - 1;
    } else {
      conv = 'f';
      prec = p - 1 - exp10;
    }
    strip = !alt;
  }

  int exp10 = 0;
  if (conv == 'f') {
    int nint = gen_f(bits, prec);
    if (!nint)
      *o++ = '0';
    for (int i = 0; i < nint; i++)
      *o++ = dg[i];
    if (prec || alt)
      *o++ = '.';
    for (int i = 0; i < prec; i++)
      *o++ = dg[nint + i];
  } else {
    exp10 = gen_e(bits, prec);
    *o++ = dg[0];
    if (prec || alt)
      *o++ = '.';
    for (int i = 1; i <= prec; i++)
      *o++ = dg[i];
  }

  if (strip && memchr(out, '.', o - out)) {
    while (o[-1] == '0')
      o--;
    if (o[-1] == '.')
      o--;
  }

  if (conv == 'e') {
    *o++ = upper ? 'E' : 'e';
    *o++ = exp10 < 0 ? '-' : '+';
    int ae = exp10 < 0 ? -exp10 : exp10;
    if (ae >= 100)
      *o++ = '0' + ae / 100;
    *o++ = '0' + ae / 10 % 10;
    *o++ = '0' + ae % 10;
  }
  *o = 0;
  return o - out;
}

// ---- 10 進 → double ----

// q × 2^x（q は 0 でない。sticky = q より下に 0 でないものがある）を double に丸める
static double make_double(u64 q, int sticky, int x, int neg) {
  int L = 64;
  while (!(q >> (L - 1)))
    L--;
  int sh = L - 53;
  if (-1074 - x > sh)
    sh = -1074 - x;                     // 非正規化数：2^-1074 の桁まで
  u64 mant;
  if (sh <= 0) {
    mant = q << -sh;
  } else {
    u64 rest;
    int half;
    if (sh >= 65) {
      mant = 0;
      half = 0;
      rest = 1;
    } else if (sh == 64) {
      mant = 0;
      half = (q >> 63) & 1;
      rest = q & ~(1ULL << 63);
    } else {
      mant = q >> sh;
      half = (q >> (sh - 1)) & 1;
      rest = sh >= 2 ? q & ((1ULL << (sh - 1)) - 1) : 0;
    }
    if (half && (rest || sticky || (mant & 1)))
      mant++;
  }
  int e2 = x + sh;                      // 値 = mant × 2^e2（e2 ≧ −1074）
  if (mant == 1ULL << 53) {
    mant >>= 1;
    e2++;
  }
  // 正規化数なら mant の 2^52 の bit が指数の欄に 1 足されるので、指数の欄は e2 + 1074 でよい
  // （非正規化数は e2 = −1074 で、mant がそのままビット列）
  u64 bits;
  if (e2 + 1075 >= 2047) {
    errno = ERANGE;
    bits = 0x7FF0000000000000ULL;
  } else {
    bits = ((u64)(e2 + 1074) << 52) + mant;
    if (!mant)
      errno = ERANGE;
  }
  return bitsd(bits | (neg ? 1ULL << 63 : 0));
}

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

static int match_word(const char *s, const char *w) {
  int i = 0;
  for (; w[i]; i++)
    if (lower(s[i]) != w[i])
      return 0;
  return i;
}

static int hexval(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  c = lower(c);
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

#define MAXDIG 800

static Big num, den;

double strtod(const char *str, char **end) {
  const char *s = str;
  while (*s == ' ' || (*s >= 9 && *s <= 13))
    s++;
  int neg = 0;
  if (*s == '+' || *s == '-')
    neg = *s++ == '-';
  double sign = neg ? -1.0 : 1.0;

  int n;
  if ((n = match_word(s, "inf"))) {
    s += n;
    if ((n = match_word(s, "inity")))
      s += n;
    if (end) *end = (char *)s;
    return sign * bitsd(0x7FF0000000000000ULL);
  }
  if ((n = match_word(s, "nan"))) {
    s += n;
    if (*s == '(') {
      const char *p = s + 1;
      while ((*p >= '0' && *p <= '9') || (lower(*p) >= 'a' && lower(*p) <= 'z') || *p == '_')
        p++;
      if (*p == ')')
        s = p + 1;
    }
    if (end) *end = (char *)s;
    return bitsd(0x7FF8000000000000ULL | (neg ? 1ULL << 63 : 0));
  }

  // 16 進：0x 仮数 p 指数
  if (s[0] == '0' && lower(s[1]) == 'x' && (hexval(s[2]) >= 0 || (s[2] == '.' && hexval(s[3]) >= 0))) {
    s += 2;
    u64 q = 0;
    int sticky = 0, x = 0, any = 0;
    for (int dot = 0;; s++) {
      if (*s == '.' && !dot) { dot = 1; continue; }
      int v = hexval(*s);
      if (v < 0)
        break;
      any = 1;
      if (q >> 60) {
        if (v) sticky = 1;
        if (!dot) x += 4;
      } else {
        q = q * 16 + v;
        if (dot) x -= 4;
      }
    }
    if (lower(*s) == 'p') {
      const char *p = s + 1;
      int en = 0;
      if (*p == '+' || *p == '-') en = *p++ == '-';
      if (*p >= '0' && *p <= '9') {
        int ev = 0;
        while (*p >= '0' && *p <= '9') {
          if (ev < 100000) ev = ev * 10 + (*p - '0');
          p++;
        }
        x += en ? -ev : ev;
        s = p;
      }
    }
    (void)any;
    if (end) *end = (char *)s;
    if (!q)
      return sign * 0.0;
    return make_double(q, sticky, x, neg);
  }

  // 10 進：数字（MAXDIG 桁まで。残りは 0 でないかだけ覚える）と指数
  static char dig[MAXDIG];
  int nd = 0, e10 = 0, sticky = 0, any = 0;
  int dot = 0;
  for (;; s++) {
    if (*s == '.' && !dot) { dot = 1; continue; }
    if (*s < '0' || *s > '9')
      break;
    any = 1;
    if (*s == '0' && nd == 0) {      // 先頭の 0
      if (dot) e10--;
      continue;
    }
    if (nd < MAXDIG) {
      dig[nd++] = *s - '0';
      if (dot) e10--;
    } else {
      if (*s != '0') sticky = 1;
      if (!dot) e10++;
    }
  }
  if (!any) {
    if (end) *end = (char *)str;
    return 0;
  }
  if (lower(*s) == 'e') {
    const char *p = s + 1;
    int en = 0;
    if (*p == '+' || *p == '-') en = *p++ == '-';
    if (*p >= '0' && *p <= '9') {
      int ev = 0;
      while (*p >= '0' && *p <= '9') {
        if (ev < 100000) ev = ev * 10 + (*p - '0');
        p++;
      }
      e10 += en ? -ev : ev;
      s = p;
    }
  }
  if (end) *end = (char *)s;

  // 末尾の 0 を指数へ
  while (nd > 0 && dig[nd - 1] == 0) {
    nd--;
    e10++;
  }
  if (nd == 0)
    return sign * 0.0;
  // 捨てた桁があれば、最後に 1 を足しておく（800 桁あれば丸めの向きは変わらない）
  if (sticky) {
    if (nd < MAXDIG) {
      dig[nd++] = 1;
      e10--;
    } else {
      dig[nd - 1] |= 1;
    }
  }
  // 範囲外：値 < 10^(nd + e10)
  if (nd + e10 > 310) {
    errno = ERANGE;
    return sign * bitsd(0x7FF0000000000000ULL);
  }
  if (nd + e10 < -330) {
    errno = ERANGE;
    return sign * 0.0;
  }

  // 速い道：15 桁以下で 10^22 まで → double の 1 回の掛け算・割り算で正しく丸まる
  if (nd <= 15 && e10 >= -22 && e10 <= 22) {
    u64 v = 0;
    for (int i = 0; i < nd; i++)
      v = v * 10 + dig[i];
    double dv = (double)v, p = 1.0;
    int ae = e10 < 0 ? -e10 : e10;
    static const double tens[] = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
                                  1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22};
    p = tens[ae];
    return sign * (e10 < 0 ? dv / p : dv * p);
  }

  // 値 = num / den × 2^x（num = 数字 × 5^e10 か、den = 5^−e10。数字は 9 桁ずつ、5 の累乗は 5^13 ずつ掛ける）
  big_set(&num, 0);
  for (int i = 0; i < nd;) {
    u32 chunk = 0, mul = 1;
    for (int k = 0; k < 9 && i < nd; k++) {
      chunk = chunk * 10 + dig[i++];
      mul *= 10;
    }
    big_muladd(&num, mul, chunk);
  }
  big_set(&den, 1);
  Big *p5 = e10 >= 0 ? &num : &den;
  int n5 = e10 >= 0 ? e10 : -e10;
  for (; n5 >= 13; n5 -= 13)
    big_muladd(p5, 1220703125, 0);
  u32 m5 = 1;
  while (n5--)
    m5 *= 5;
  big_muladd(p5, m5, 0);
  int x = e10;
  // q = num × 2^s / den が 2^62〜2^64 になるように
  int s2 = 63 + big_bits(&den) - big_bits(&num);
  if (s2 > 0)
    big_shl(&num, s2);
  else
    big_shl(&den, -s2);
  x -= s2;
  // 1 bit ずつ割る（den × 2^63 から始める）
  big_shl(&den, 63);
  u64 q = 0;
  for (int i = 63; i >= 0; i--) {
    if (big_cmp(&num, &den) >= 0) {
      big_sub(&num, &den);
      q |= 1ULL << i;
    }
    big_shr1(&den);
  }
  return make_double(q, num.n != 0, x, neg);
}

float strtof(const char *s, char **end) {
  return (float)strtod(s, end);   // 2 回丸めるが、ほとんどの場合は同じ
}

long double strtold(const char *s, char **end) {
  return strtod(s, end);
}

double atof(const char *s) {
  return strtod(s, 0);
}
