// long long の割り算・余り（cc/codegen.c が呼ぶ）。CPU の割り算は 32bit なので、引き算とシフトで求める
static unsigned long long udivmod(unsigned long long n, unsigned long long d, unsigned long long *rem) {
  if (d == 0) {
    volatile int zero = 0;
    return 1 / zero;                   // 32bit と同じく「0 で割る」例外にする
  }
  // どちらも 32bit に収まるなら、CPU の割り算で
  if ((n >> 32) == 0 && (d >> 32) == 0) {
    unsigned a = n, b = d;
    if (rem)
      *rem = a % b;
    return a / b;
  }
  unsigned long long q = 0, r = 0;
  for (int i = 63; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if (r >= d) {
      r -= d;
      q |= 1ULL << i;
    }
  }
  if (rem)
    *rem = r;
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
