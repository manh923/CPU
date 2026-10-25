// long long の割り算・余り（cc/codegen.c が呼ぶ）。CPU の割り算は 32bit なので、それを組み合わせる
// （Hacker's Delight の divlu・divdu：16bit ずつ商を見積もって直す。1 bit ずつ引くより何十倍も速い）

// 上の 0 の bit の数（x ≠ 0）
static int nlz(unsigned x) {
  int n = 0;
  if (!(x >> 16)) { n += 16; x <<= 16; }
  if (!(x >> 24)) { n += 8; x <<= 8; }
  if (!(x >> 28)) { n += 4; x <<= 4; }
  if (!(x >> 30)) { n += 2; x <<= 2; }
  if (!(x >> 31)) n += 1;
  return n;
}

// (u1:u0) ÷ v（u1 < v）。商は 32bit に収まる
static unsigned divlu(unsigned u1, unsigned u0, unsigned v, unsigned *r) {
  const unsigned b = 65536;
  int s = nlz(v);
  v <<= s;                              // v の一番上の bit を 1 に
  unsigned vn1 = v >> 16, vn0 = v & 0xFFFF;
  unsigned un32 = s ? (u1 << s) | (u0 >> (32 - s)) : u1;
  unsigned un10 = u0 << s;
  unsigned un1 = un10 >> 16, un0 = un10 & 0xFFFF;

  unsigned q1 = un32 / vn1, rhat = un32 - q1 * vn1;
  while (q1 >= b || q1 * vn0 > b * rhat + un1) {
    q1--;
    rhat += vn1;
    if (rhat >= b)
      break;
  }
  unsigned un21 = un32 * b + un1 - q1 * v;

  unsigned q0 = un21 / vn1;
  rhat = un21 - q0 * vn1;
  while (q0 >= b || q0 * vn0 > b * rhat + un0) {
    q0--;
    rhat += vn1;
    if (rhat >= b)
      break;
  }
  if (r)
    *r = (un21 * b + un0 - q0 * v) >> s;
  return q1 * b + q0;
}

static unsigned long long udivmod(unsigned long long n, unsigned long long d, unsigned long long *rem) {
  if (d == 0) {
    volatile int zero = 0;
    return 1 / zero;                   // 32bit と同じく「0 で割る」例外にする
  }
  unsigned nh = n >> 32, nl = n, dh = d >> 32, dl = d;
  if (dh == 0) {
    if (nh == 0) {                     // どちらも 32bit：CPU の割り算で
      if (rem)
        *rem = nl % dl;
      return nl / dl;
    }
    // 割る数が 32bit：上の 32bit を割ってから、余りと下の 32bit を divlu で
    unsigned qh = nh / dl, r;
    unsigned ql = divlu(nh % dl, nl, dl, &r);
    if (rem)
      *rem = r;
    return (unsigned long long)qh << 32 | ql;
  }
  // 割る数が 32bit より大きい：商は 32bit に収まる。上を揃えて見積もり、1 だけ直す（divdu）
  int s = nlz(dh);
  unsigned v1 = (unsigned)((d << s) >> 32);
  unsigned long long u1 = n >> 1;
  unsigned long long q = divlu((unsigned)(u1 >> 32), (unsigned)u1, v1, 0);
  q = (q << s) >> 31;
  if (q)
    q--;
  if (n - q * d >= d)
    q++;
  if (rem)
    *rem = n - q * d;
  return q;
}

unsigned long long __udivdi3(unsigned long long a, unsigned long long b) {
  return udivmod(a, b, 0);
}

unsigned long long __umoddi3(unsigned long long a, unsigned long long b) {
  unsigned long long r;
  udivmod(a, b, &r);
  return r;
}

long long __divdi3(long long a, long long b) {
  unsigned long long ua = a < 0 ? -(unsigned long long)a : a;
  unsigned long long ub = b < 0 ? -(unsigned long long)b : b;
  unsigned long long q = udivmod(ua, ub, 0);
  return (a < 0) != (b < 0) ? -(long long)q : (long long)q;
}

long long __moddi3(long long a, long long b) {
  unsigned long long ua = a < 0 ? -(unsigned long long)a : a;
  unsigned long long ub = b < 0 ? -(unsigned long long)b : b;
  unsigned long long r;
  udivmod(ua, ub, &r);
  return a < 0 ? -(long long)r : (long long)r;   // 余りの符号は割られる数と同じ
}
