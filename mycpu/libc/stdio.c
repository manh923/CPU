// 標準入出力（画面と UART。MyDOS の SYSCALL を使う）。printf の仲間はここで書式を作る
#include <stdio.h>
#include <string.h>
#include <mycpu.h>

int putchar(int c) {
  __syscall(SYS_PUTC, c & 0xff, 0, 0);
  return c & 0xff;
}

int puts(const char *s) {
  __syscall(SYS_PUTS, (int)s, 0, 0);
  putchar('\n');
  return 0;
}

int getchar(void) {
  return __syscall(SYS_GETC, 0, 0, 0);
}

// 書式の出力先：文字列（n バイトまで）か画面
typedef struct {
  char *buf;      // NULL なら画面
  size_t n;       // buf の大きさ
  size_t len;     // 出した文字数（入りきらなかった分も数える）
} Out;

static void out_c(Out *o, int c) {
  if (o->buf) {
    if (o->len + 1 < o->n)
      o->buf[o->len] = c;
  } else {
    putchar(c);
  }
  o->len++;
}

static void out_pad(Out *o, int c, int n) {
  while (n-- > 0)
    out_c(o, c);
}

// 数を文字列に（逆順にためて返す）。戻り値は桁数
static int utoa_rev(unsigned long long v, int base, int upper, char *tmp) {
  char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  int n = 0;
  do {
    tmp[n++] = digits[v % base];
    v /= base;
  } while (v);
  return n;
}

static int format(Out *o, const char *f, va_list ap) {
  for (; *f; f++) {
    if (*f != '%') {
      out_c(o, *f);
      continue;
    }
    f++;

    // 旗：- 左寄せ、0 ゼロで埋める、+ 符号、空白
    int left = 0, zero = 0, plus = 0, space = 0, alt = 0;
    for (;; f++) {
      if (*f == '-') left = 1;
      else if (*f == '0') zero = 1;
      else if (*f == '+') plus = 1;
      else if (*f == ' ') space = 1;
      else if (*f == '#') alt = 1;
      else break;
    }

    // 幅と精度（* なら引数から）
    int width = 0, prec = -1;
    if (*f == '*') {
      width = va_arg(ap, int);
      if (width < 0) { left = 1; width = -width; }
      f++;
    } else {
      while (*f >= '0' && *f <= '9')
        width = width * 10 + (*f++ - '0');
    }
    if (*f == '.') {
      f++;
      prec = 0;
      if (*f == '*') {
        prec = va_arg(ap, int);
        f++;
      } else {
        while (*f >= '0' && *f <= '9')
          prec = prec * 10 + (*f++ - '0');
      }
    }

    // 長さ：ll（と j）は long long。int・long・ポインタはどれも 4 バイトなので、ほかは読み飛ばす
    int nl = 0;
    while (*f == 'l' || *f == 'h' || *f == 'z' || *f == 't' || *f == 'j') {
      if (*f == 'l')
        nl++;
      if (*f == 'j')
        nl = 2;
      f++;
    }
    int is_ll = nl >= 2;

    char tmp[24];
    char *prefix = "";
    int n;

    switch (*f) {
    case 'd':
    case 'i': {
      long long v = is_ll ? va_arg(ap, long long) : va_arg(ap, int);
      unsigned long long u = v < 0 ? -(unsigned long long)v : v;
      prefix = v < 0 ? "-" : plus ? "+" : space ? " " : "";
      n = utoa_rev(u, 10, 0, tmp);
      goto number;
    }
    case 'u':
      n = utoa_rev(is_ll ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned), 10, 0, tmp);
      goto number;
    case 'x':
    case 'X': {
      unsigned long long v = is_ll ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned);
      if (alt && v)
        prefix = *f == 'x' ? "0x" : "0X";
      n = utoa_rev(v, 16, *f == 'X', tmp);
      goto number;
    }
    case 'o': {
      unsigned long long v = is_ll ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned);
      if (alt && v)
        prefix = "0";
      n = utoa_rev(v, 8, 0, tmp);
      goto number;
    }
    case 'p':
      prefix = "0x";
      n = utoa_rev((unsigned)va_arg(ap, void *), 16, 0, tmp);
      goto number;
    number: {
      // 精度は最低の桁数。0 埋めは精度がないときだけ
      if (prec == 0 && n == 1 && tmp[0] == '0')
        n = 0;
      int digits = prec > n ? prec : n;
      int plen = strlen(prefix);
      int pad = width - digits - plen;
      if (!left && !(zero && prec < 0))
        out_pad(o, ' ', pad);
      for (char *p = prefix; *p; p++)
        out_c(o, *p);
      if (!left && zero && prec < 0)
        out_pad(o, '0', pad);
      out_pad(o, '0', digits - n);
      while (n > 0)
        out_c(o, tmp[--n]);
      if (left)
        out_pad(o, ' ', pad);
      break;
    }
    case 'c': {
      char c = va_arg(ap, int);
      if (!left)
        out_pad(o, ' ', width - 1);
      out_c(o, c);
      if (left)
        out_pad(o, ' ', width - 1);
      break;
    }
    case 's': {
      char *s = va_arg(ap, char *);
      if (!s)
        s = "(null)";
      int len = 0;
      while (s[len] && (prec < 0 || len < prec))
        len++;
      if (!left)
        out_pad(o, ' ', width - len);
      for (int i = 0; i < len; i++)
        out_c(o, s[i]);
      if (left)
        out_pad(o, ' ', width - len);
      break;
    }
    case '%':
      out_c(o, '%');
      break;
    case 0:
      return o->len;
    default:
      out_c(o, '%');
      out_c(o, *f);
    }
  }
  return o->len;
}

int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap) {
  Out o = {buf, n, 0};
  format(&o, fmt, ap);
  if (n)
    buf[o.len < n ? o.len : n - 1] = 0;
  return o.len;
}

int vsprintf(char *buf, const char *fmt, va_list ap) {
  return vsnprintf(buf, 0x7fffffff, fmt, ap);
}

int vprintf(const char *fmt, va_list ap) {
  Out o = {0, 0, 0};
  return format(&o, fmt, ap);
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vprintf(fmt, ap);
  va_end(ap);
  return n;
}

int sprintf(char *buf, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vsprintf(buf, fmt, ap);
  va_end(ap);
  return n;
}

int snprintf(char *buf, size_t n, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsnprintf(buf, n, fmt, ap);
  va_end(ap);
  return r;
}
