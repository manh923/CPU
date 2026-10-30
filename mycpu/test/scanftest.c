// libc/scanf.c のテスト：PC の gcc でビルドし（scanf.c は名前を my_ に変えて取り込む）、glibc の sscanf と比べる
// （戻り値・しまった値・%n）。test/run.js が動かす
//   gcc -O1 -o scanftest test/scanftest.c && ./scanftest [回数]
// 決まった例と、ランダムに作った書式・入力を比べる。違えば NG を出す
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int (*glibc_sscanf)(const char *, const char *, ...) = sscanf;

#undef scanf
#undef fscanf
#undef sscanf
#undef vscanf
#undef vfscanf
#undef vsscanf
#define scanf my_scanf
#define fscanf my_fscanf
#define sscanf my_sscanf
#define vscanf my_vscanf
#define vfscanf my_vfscanf
#define vsscanf my_vsscanf
#include "../libc/scanf.c"
#undef sscanf

typedef unsigned long long u64;
static u64 state = 88172645463325252ULL;
static u64 rnd(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

static int ng, total;

// 1 つの書式・入力で、両方の sscanf を呼んで比べる。書式の変換は最大 4 つ、値は 64 バイトの箱に入れる
// （箱は前もって同じ値で埋めておくので、しまわなかったところも同じになる）
static void check(const char *in, const char *fmt) {
  union { char b[64]; long long ll; double d; } a[4], b[4];
  int na = -7, nb = -7;
  memset(a, 0x5A, sizeof(a));
  memset(b, 0x5A, sizeof(b));
  int ra = glibc_sscanf(in, fmt, &a[0], &a[1], &a[2], &a[3]);
  int rb = my_sscanf(in, fmt, &b[0], &b[1], &b[2], &b[3]);
  (void)na;
  (void)nb;
  total++;
  if (ra != rb || memcmp(a, b, sizeof(a))) {
    if (ng++ < 30) {
      printf("NG 入力 \"%s\" 書式 \"%s\"：glibc %d、こちら %d\n", in, fmt, ra, rb);
      for (int i = 0; i < 4; i++)
        if (memcmp(&a[i], &b[i], sizeof(a[i])))
          printf("   %d 番目：glibc %016llx こちら %016llx（%.17g / %.17g、\"%.20s\" / \"%.20s\"）\n", i, a[i].ll, b[i].ll,
                 a[i].d, b[i].d, a[i].b, b[i].b);
    }
  }
}

static const char *pick(const char **v, int n) { return v[rnd() % n]; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 20000;
  // 決まった例
  const char *cases[][2] = {
    {"42", "%d"}, {"-17 x", "%d %c"}, {"  +8", "%d"}, {"0x1F", "%x"}, {"0x1F", "%i"}, {"017", "%i"}, {"-0x10", "%i"},
    {"777", "%o"}, {"ff", "%X"}, {"123456789012", "%lld"}, {"-9223372036854775808", "%lld"}, {"18446744073709551615", "%llu"},
    {"12 34", "%2d%d"}, {"12345", "%3d%d"}, {"abc def", "%s %s"}, {"abc def", "%2s%s"}, {"hello", "%3c"},
    {"a,b,c", "%[^,],%[^,],%s"}, {"abc123", "%[a-z]%d"}, {"]x", "%[]x]"}, {"  x", "%c"}, {"  x", " %c"},
    {"1.5", "%f"}, {"-2.25e3", "%lf"}, {"0x1.8p1", "%lf"}, {"inf", "%lf"}, {"-INFINITY", "%lf"}, {"nan", "%lf"},
    {"3.14abc", "%lf%s"}, {".5", "%f"}, {"5.", "%f"}, {"1e", "%f"}, {"1e+", "%lf"}, {"1e5x", "%lf%c"},
    {"12abc", "%d%n"}, {"abc", "%n%s%n"}, {"", "%d"}, {"   ", "%d"}, {"", "%n"}, {"x", "%d"}, {"5", "x%d"},
    {"%5", "%%%d"}, {"10 20", "%*d %d"}, {"7", "%hhd"}, {"300", "%hhu"}, {"70000", "%hd"}, {"-1", "%hu"},
    {"0x", "%x"}, {"0xg", "%x%c"}, {"-", "%d"}, {"+", "%x"}, {"1234567", "%4lf%d"}, {"abc", "%2c%c"},
    {"ab", "%3c"}, {"a b", "%c%c%c"}, {"123", "%1d%1d%1d"}, {"0x10", "%2x%d"}, {"0.25", "%3f%f"},
  };
  for (unsigned i = 0; i < sizeof(cases) / sizeof(*cases); i++)
    check(cases[i][0], cases[i][1]);

  // ランダム：入力のかけらと、それに合いそうな変換を並べる
  const char *nums[] = {"0", "7", "-12", "+345", "0x1aF", "0777", "2147483647", "-2147483648", "4294967295",
                        "99999999999", "1.5", "-0.125", "6.02e23", "1e-5", "0x1p-3", "inf", "nan", ".75", "abc", "x9",
                        "  42", "\t-8", "12abc", "007", "1e400", "4.9e-324"};
  // 区切りなしでつなぐと 64bit を超える数ができる（あふれたときの値は規格で決まっていない）ので、いつも区切る
  const char *seps[] = {" ", "  ", ",", "\t", ";", "\n"};
  const char *convs[] = {"%d", "%i", "%u", "%x", "%o", "%hd", "%hhd", "%lld", "%llu", "%lf", "%f", "%e", "%g",
                         "%s", "%c", "%3d", "%2s", "%5c", "%[0-9]", "%[^ ,]", "%*d", "%n", "%lx"};  // %Lf は PC の long double が違うので比べない
  for (long k = 0; k < n; k++) {
    char in[256] = "", fmt[128] = "";
    int nconv = 0;
    int parts = 1 + rnd() % 4;
    for (int i = 0; i < parts; i++) {
      strcat(in, pick(nums, sizeof(nums) / sizeof(*nums)));
      strcat(in, pick(seps, sizeof(seps) / sizeof(*seps)));
    }
    int nf = 1 + rnd() % 4;
    for (int i = 0; i < nf && nconv < 4; i++) {
      const char *cv = pick(convs, sizeof(convs) / sizeof(*convs));
      strcat(fmt, cv);
      if (strcmp(cv, "%*d"))
        nconv++;
      if (rnd() % 2)
        strcat(fmt, rnd() % 3 ? " " : ",");
    }
    check(in, fmt);
  }
  printf("scanftest: %d 通り, %d NG\n", total, ng);
  return ng != 0;
}
