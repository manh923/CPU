// scanf の仲間：書式に合わせて文字を読み、値をしまう（C の規格どおり）。
//   scanf・fscanf・sscanf と v の付いたもの。%d %i %u %o %x %X %p %c %s %[...] %n %% と %f %e %g %a（大文字も）、
//   幅、*（読むだけでしまわない）、長さ hh h l ll j z t L（int・long・ポインタは 4 バイト、long long は 8 バイト、
//   long double は double と同じ）
//   戻り値はしまった数。何かを変換する前に入力が終わったら EOF
// PC の gcc でもコンパイルでき、glibc の sscanf と同じ結果になるかを test/scanftest.c で確かめる
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 読み元：文字列か FILE
typedef struct {
  const char *s;
  FILE *fp;
  int n;                         // 読んだ文字数（%n）
} In;

static int get(In *in) {
  int c;
  if (in->fp)
    c = fgetc(in->fp);
  else
    c = *in->s ? (unsigned char)*in->s++ : EOF;
  if (c != EOF)
    in->n++;
  return c;
}

static void unget(In *in, int c) {
  if (c == EOF)
    return;
  in->n--;
  if (in->fp)
    ungetc(c, in->fp);
  else
    in->s--;
}

// 幅の残り left のあいだだけ読む（なくなったら EOF。読まない）
static int wget(In *in, int *left) {
  if (*left <= 0)
    return EOF;
  (*left)--;
  return get(in);
}

static void wunget(In *in, int *left, int c) {
  if (c == EOF)
    return;
  (*left)++;
  unget(in, c);
}

// 小数の変換は、float・double を使うプログラムだけ（AS -lib の弱い名前。libc/stdio.c の __mycpu_weak_dtoa と同じ）
double (*__mycpu_weak_strtod)(const char *, char **) = strtod;

// 整数をしまう（長さ：'H' = hh、'h'、0 = int、'l'、'L' = ll）
static void store_int(va_list ap, int len, unsigned long long v) {
  switch (len) {
  case 'H': *va_arg(ap, signed char *) = (signed char)v; break;
  case 'h': *va_arg(ap, short *) = (short)v; break;
  case 'l': *va_arg(ap, long *) = (long)v; break;
  case 'L': *va_arg(ap, long long *) = (long long)v; break;
  default: *va_arg(ap, int *) = (int)v;
  }
}

static int digit_val(int c) {
  if (isdigit(c))
    return c - '0';
  if (c >= 'a' && c <= 'z')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'Z')
    return c - 'A' + 10;
  return 99;
}

// 小数の文字を buf に集める（符号、inf・infinity・nan・nan(…)、0x の 16 進、10 進と指数）。正しい形なら 1
static int read_float(In *in, int left, char *buf, int size) {
  int n = 0, digits = 0;
  if (left > size - 1)
    left = size - 1;
  int c = wget(in, &left);
#define TAKE() (buf[n++] = c, c = wget(in, &left))
  if (c == '+' || c == '-')
    TAKE();
  if (c == 'i' || c == 'I' || c == 'n' || c == 'N') {
    const char *w = (c == 'i' || c == 'I') ? "infinity" : "nan";
    int k = 0;
    while (w[k] && c != EOF && tolower(c) == w[k]) {
      TAKE();
      k++;
    }
    if (k < 3 || (w[0] == 'i' && k > 3 && k < 8))
      goto bad;                    // 足りない・「infin」などで途中まで
    if (w[0] == 'n' && c == '(') {   // nan(文字)
      TAKE();
      while (c != EOF && (isalnum(c) || c == '_'))
        TAKE();
      if (c != ')')
        goto bad;
      TAKE();
    }
    goto ok;
  }
  int hex = 0;
  if (c == '0') {
    TAKE();
    digits = 1;
    if (c == 'x' || c == 'X') {
      hex = 1;
      digits = 0;
      TAKE();
    }
  }
  while (c != EOF && (hex ? isxdigit(c) : isdigit(c))) {
    TAKE();
    digits++;
  }
  if (c == '.') {
    TAKE();
    while (c != EOF && (hex ? isxdigit(c) : isdigit(c))) {
      TAKE();
      digits++;
    }
  }
  if (!digits)
    goto bad;
  if (hex ? (c == 'p' || c == 'P') : (c == 'e' || c == 'E')) {
    int e = n;
    TAKE();
    if (c == '+' || c == '-')
      TAKE();
    if (c == EOF || !isdigit(c)) {     // 「1e」「1e+」：指数の前までを数にする（glibc と同じ。読んだ e・符号は戻さない）
      wunget(in, &left, c);
      buf[e] = 0;
      return 1;
    }
    while (c != EOF && isdigit(c))
      TAKE();
  }
ok:
  wunget(in, &left, c);
  buf[n] = 0;
  return 1;
bad:
  wunget(in, &left, c);
  return 0;
#undef TAKE
}

static int scan(In *in, const char *f, va_list ap) {
  int count = 0, c = 0;
  for (; *f; f++) {
    // 空白：入力の空白をいくつでも飛ばす
    if (isspace((unsigned char)*f)) {
      while (isspace(c = get(in)))
        ;
      unget(in, c);
      continue;
    }
    // ふつうの文字・%%：同じ文字でなければ終わり
    if (*f != '%' || f[1] == '%') {
      if (*f == '%') {
        f++;
        while (isspace(c = get(in)))
          ;
      } else {
        c = get(in);
      }
      if (c != (unsigned char)*f) {
        unget(in, c);
        return c == EOF && !count ? EOF : count;
      }
      continue;
    }

    f++;
    int skip = 0, width = 0, len = 0;
    if (*f == '*') {
      skip = 1;
      f++;
    }
    while (isdigit((unsigned char)*f))
      width = width * 10 + (*f++ - '0');
    if (*f == 'h') {
      f++;
      len = 'h';
      if (*f == 'h') {
        f++;
        len = 'H';
      }
    } else if (*f == 'l') {
      f++;
      len = 'l';
      if (*f == 'l') {
        f++;
        len = 'L';
      }
    } else if (*f == 'L' || *f == 'j' || *f == 'q') {
      f++;
      len = 'L';
    } else if (*f == 'z' || *f == 't') {
      f++;
      len = 'l';
    }
    int conv = *f;
    if (!conv)
      break;

    if (conv == 'n') {
      if (!skip)
        store_int(ap, len, in->n);
      continue;
    }
    // %c・%[ のほかは、先の空白を飛ばす
    if (conv != 'c' && conv != '[') {
      while (isspace(c = get(in)))
        ;
      unget(in, c);
    }
    if (!width)
      width = conv == 'c' ? 1 : 0x7FFFFFFF;

    switch (conv) {
    case 'd':
    case 'i':
    case 'u':
    case 'o':
    case 'x':
    case 'X':
    case 'p': {
      int base = conv == 'o' ? 8 : (conv == 'x' || conv == 'X' || conv == 'p') ? 16 : conv == 'i' ? 0 : 10;
      int left = width, neg = 0, digits = 0;
      unsigned long long v = 0;
      c = wget(in, &left);
      if (c == EOF)
        return count ? count : EOF;
      if (c == '+' || c == '-') {
        neg = c == '-';
        c = wget(in, &left);
      }
      if (c == '0' && (base == 0 || base == 16)) {   // 0x の 16 進、0 の 8 進（%i）
        digits = 1;
        c = wget(in, &left);
        if (c == 'x' || c == 'X') {
          base = 16;
          c = wget(in, &left);
        } else if (base == 0) {
          base = 8;
        }
      }
      if (base == 0)
        base = 10;
      while (c != EOF && digit_val(c) < base) {
        v = v * base + digit_val(c);
        digits++;
        c = wget(in, &left);
      }
      wunget(in, &left, c);
      if (!digits)
        return count;
      if (neg)
        v = -v;
      if (!skip) {
        if (conv == 'p')
          *va_arg(ap, void **) = (void *)(unsigned long)v;
        else
          store_int(ap, len, v);
        count++;
      }
      break;
    }
    case 'f':
    case 'e':
    case 'g':
    case 'a':
    case 'F':
    case 'E':
    case 'G':
    case 'A': {
      char buf[512];
      c = get(in);
      if (c == EOF)
        return count ? count : EOF;
      unget(in, c);
      if (!read_float(in, width, buf, sizeof(buf)) || !__mycpu_weak_strtod)
        return count;
      double d = __mycpu_weak_strtod(buf, 0);
      if (!skip) {
        if (len == 'l' || len == 'L')
          *va_arg(ap, double *) = d;
        else
          *va_arg(ap, float *) = (float)d;
        count++;
      }
      break;
    }
    case 's':
    case 'c':
    case '[': {
      // %[：集合（^ で反対。最初の ] は文字。a-z は範囲）
      char set[256];
      if (conv == '[') {
        int neg = 0;
        f++;
        if (*f == '^') {
          neg = 1;
          f++;
        }
        memset(set, neg, sizeof(set));
        if (*f == ']') {
          set[']'] = !neg;
          f++;
        }
        for (; *f && *f != ']'; f++) {
          if (f[1] == '-' && f[2] && f[2] != ']') {
            for (int k = (unsigned char)f[0]; k <= (unsigned char)f[2]; k++)
              set[k] = !neg;
            f += 2;
          } else {
            set[(unsigned char)*f] = !neg;
          }
        }
        if (!*f)
          return count;
      }
      char *out = skip ? 0 : va_arg(ap, char *);
      int n = 0;
      while (n < width) {
        c = get(in);
        if (c == EOF)
          break;
        if ((conv == 's' && isspace(c)) || (conv == '[' && !set[c])) {
          unget(in, c);
          break;
        }
        if (out)
          out[n] = c;
        n++;
      }
      if (!n)
        return c == EOF && !count ? EOF : count;
      if (out && conv != 'c')            // %c は幅の数に足りなくても、読めた分で成功（glibc と同じ）
        out[n] = 0;
      if (!skip)
        count++;
      break;
    }
    default:
      return count;
    }
  }
  return count;
}

int vsscanf(const char *s, const char *fmt, va_list ap) {
  In in = {s, 0, 0};
  return scan(&in, fmt, ap);
}

int vfscanf(FILE *fp, const char *fmt, va_list ap) {
  In in = {0, fp, 0};
  return scan(&in, fmt, ap);
}

int vscanf(const char *fmt, va_list ap) {
  return vfscanf(stdin, fmt, ap);
}

int sscanf(const char *s, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsscanf(s, fmt, ap);
  va_end(ap);
  return r;
}

int fscanf(FILE *fp, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vfscanf(fp, fmt, ap);
  va_end(ap);
  return r;
}

int scanf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vfscanf(stdin, fmt, ap);
  va_end(ap);
  return r;
}
