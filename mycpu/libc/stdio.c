// 標準入出力：FILE（MyDOS のファイル・キーボード・画面）と printf の仲間。MyDOS の SYSCALL を使う
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <mycpu.h>

// ---- FILE ----
// 読む：BUFSIZ バイトずつ MyDOS から読んでためる。書く：ためて、いっぱいか fflush・fclose で書く。
// stdin はキーボード（SYS_GETLINE で 1 行ずつ。文字が画面に出て、Backspace が効く）、stdout・stderr は画面（ためない）
static FILE f_stdin = {-2, 'r', 0, 0, -1, 0, 0, 0};
static FILE f_stdout = {-1, 'w', 0, 0, -1, 0, 0, 0};
static FILE f_stderr = {-1, 'w', 0, 0, -1, 0, 0, 0};
FILE *stdin = &f_stdin;
FILE *stdout = &f_stdout;
FILE *stderr = &f_stderr;
static unsigned char stdin_buf[BUFSIZ];

// MyDOS のエラー（負の数）→ errno
static int set_errno(int r) {
  static int map[] = {0, EBADF, ENOENT, EMFILE, ENOSPC, EACCES, EINVAL, EIO};
  errno = (r < 0 && r >= -7) ? map[-r] : EIO;
  return -1;
}

FILE *fopen(const char *name, const char *mode) {
  int m;                                 // MyDOS：0 = 読む、1 = 新しく書く、2 = 後ろに足す
  if (mode[0] == 'r' && !strchr(mode, '+'))
    m = 0;
  else if (mode[0] == 'w')
    m = 1;
  else if (mode[0] == 'a')
    m = 2;
  else {
    errno = EINVAL;                      // r+ は MyDOS ではできない
    return 0;
  }
  FILE *fp = calloc(1, sizeof(FILE));
  unsigned char *buf = malloc(BUFSIZ);
  if (!fp || !buf) {
    free(fp);
    free(buf);
    errno = ENOMEM;
    return 0;
  }
  int fd = __syscall(SYS_OPEN, (int)name, m, 0);
  if (fd < 0) {
    set_errno(fd);
    free(fp);
    free(buf);
    return 0;
  }
  fp->fd = fd;
  fp->mode = m == 0 ? 'r' : 'w';
  fp->ungot = -1;
  fp->buf = buf;
  return fp;
}

int fflush(FILE *fp) {
  if (!fp || fp->fd < 0 || fp->mode != 'w' || fp->pos == 0)
    return 0;
  int r = __syscall(SYS_WRITE, fp->fd, (int)fp->buf, fp->pos);
  fp->pos = 0;
  if (r < 0) {
    fp->err = 1;
    return set_errno(r);
  }
  return 0;
}

int fclose(FILE *fp) {
  if (fp->fd < 0)
    return 0;
  int r = fflush(fp);
  int c = __syscall(SYS_CLOSE, fp->fd, 0, 0);
  free(fp->buf);
  free(fp);
  if (c < 0)
    return set_errno(c);
  return r;
}

// 読む：buf が空なら読み足す。戻り値は読めたバイト数（0 で終わり）
static int fill(FILE *fp) {
  if (fp->fd == -2) {
    if (!fp->buf)
      fp->buf = stdin_buf;
    int n = __syscall(SYS_GETLINE, (int)fp->buf, BUFSIZ - 2, 0);   // Enter の改行は BIOS が画面に出す
    fp->buf[n] = '\n';
    fp->len = n + 1;
  } else {
    int n = __syscall(SYS_READ, fp->fd, (int)fp->buf, BUFSIZ);
    if (n < 0) {
      fp->err = 1;
      set_errno(n);
      n = 0;
    }
    fp->len = n;
  }
  fp->pos = 0;
  if (fp->len == 0)
    fp->eof = 1;
  return fp->len;
}

int fgetc(FILE *fp) {
  if (fp->ungot >= 0) {
    int c = fp->ungot;
    fp->ungot = -1;
    return c;
  }
  if (fp->mode != 'r' || fp->eof)
    return EOF;
  if (fp->pos >= fp->len && !fill(fp))
    return EOF;
  return fp->buf[fp->pos++];
}

int getc(FILE *fp) { return fgetc(fp); }
int getchar(void) { return fgetc(stdin); }

int ungetc(int c, FILE *fp) {
  if (c == EOF)
    return EOF;
  fp->ungot = c & 0xff;
  fp->eof = 0;
  return c;
}

int fputc(int c, FILE *fp) {
  if (fp->fd == -1) {
    __syscall(SYS_PUTC, c & 0xff, 0, 0);
    return c & 0xff;
  }
  if (fp->mode != 'w')
    return EOF;
  fp->buf[fp->pos++] = c;
  if (fp->pos == BUFSIZ && fflush(fp) < 0)
    return EOF;
  return c & 0xff;
}

int putc(int c, FILE *fp) { return fputc(c, fp); }
int putchar(int c) { return fputc(c, stdout); }

int fputs(const char *s, FILE *fp) {
  if (fp->fd == -1) {
    __syscall(SYS_PUTS, (int)s, 0, 0);
    return 0;
  }
  for (; *s; s++)
    if (fputc(*s, fp) == EOF)
      return EOF;
  return 0;
}

int puts(const char *s) {
  fputs(s, stdout);
  return putchar('\n') == EOF ? EOF : 0;
}

char *fgets(char *s, int n, FILE *fp) {
  int i = 0;
  while (i < n - 1) {
    int c = fgetc(fp);
    if (c == EOF)
      break;
    s[i++] = c;
    if (c == '\n')
      break;
  }
  if (i == 0)
    return 0;
  s[i] = 0;
  return s;
}

size_t fread(void *p, size_t size, size_t n, FILE *fp) {
  unsigned char *d = p;
  size_t want = size * n, got = 0;
  if (fp->ungot >= 0 && want) {
    d[got++] = fp->ungot;
    fp->ungot = -1;
  }
  while (got < want) {
    if (fp->pos < fp->len) {             // ためてある分から
      size_t k = fp->len - fp->pos;
      if (k > want - got)
        k = want - got;
      memcpy(d + got, fp->buf + fp->pos, k);
      fp->pos += k;
      got += k;
      continue;
    }
    if (fp->mode != 'r' || fp->eof)
      break;
    if (fp->fd >= 0 && want - got >= BUFSIZ) {   // 大きければ直接読む
      int r = __syscall(SYS_READ, fp->fd, (int)(d + got), (want - got) / BUFSIZ * BUFSIZ);
      if (r <= 0) {
        if (r < 0) {
          fp->err = 1;
          set_errno(r);
        }
        fp->eof = 1;
        break;
      }
      got += r;
      continue;
    }
    if (!fill(fp))
      break;
  }
  return size ? got / size : 0;
}

size_t fwrite(const void *p, size_t size, size_t n, FILE *fp) {
  const unsigned char *s = p;
  size_t want = size * n;
  if (fp->fd == -1) {
    for (size_t i = 0; i < want; i++)
      __syscall(SYS_PUTC, s[i], 0, 0);
    return n;
  }
  if (fp->mode != 'w')
    return 0;
  for (size_t i = 0; i < want; i++) {
    fp->buf[fp->pos++] = s[i];
    if (fp->pos == BUFSIZ && fflush(fp) < 0)
      return size ? i / size : 0;
  }
  return n;
}

int feof(FILE *fp) { return fp->eof; }
int ferror(FILE *fp) { return fp->err; }
void clearerr(FILE *fp) { fp->eof = fp->err = 0; }
int fileno(FILE *fp) { return fp->fd; }
int setvbuf(FILE *fp, char *buf, int mode, size_t size) { return 0; }

// 位置：読むファイルは ためてある分を捨てて MyDOS の位置を動かす。書くファイルは終わりだけ（MyDOS の都合）
int fseek(FILE *fp, long off, int whence) {
  if (fp->fd < 0) {
    errno = EBADF;
    return -1;
  }
  if (fp->mode == 'r' && whence == SEEK_CUR)
    off -= (fp->len - fp->pos) + (fp->ungot >= 0);
  if (fflush(fp) < 0)
    return -1;
  int r = __syscall(SYS_SEEK, fp->fd, off, whence);
  if (r < 0)
    return set_errno(r);
  fp->pos = fp->len = 0;
  fp->ungot = -1;
  fp->eof = 0;
  return 0;
}

long ftell(FILE *fp) {
  if (fp->fd < 0) {
    errno = EBADF;
    return -1;
  }
  int r = __syscall(SYS_SEEK, fp->fd, 0, SEEK_CUR);
  if (r < 0)
    return set_errno(r);
  if (fp->mode == 'r')
    return r - (fp->len - fp->pos) - (fp->ungot >= 0);
  return r + fp->pos;
}

void rewind(FILE *fp) {
  fseek(fp, 0, SEEK_SET);
  clearerr(fp);
}

int remove(const char *name) {
  int r = __syscall(SYS_DELETE, (int)name, 0, 0);
  return r < 0 ? set_errno(r) : 0;
}

int rename(const char *from, const char *to) {
  int r = __syscall(SYS_RENAME, (int)from, (int)to, 0);
  return r < 0 ? set_errno(r) : 0;
}

void perror(const char *s) {
  if (s && *s)
    fprintf(stderr, "%s: ", s);
  fprintf(stderr, "%s\n", strerror(errno));
}

void __assert_fail(const char *expr, const char *file, int line) {
  fprintf(stderr, "%s:%d: assertion failed: %s\n", file, line, expr);
  exit(1);
}

// 書式の出力先：文字列（n バイトまで）か FILE
typedef struct {
  char *buf;      // NULL なら fp へ
  size_t n;       // buf の大きさ
  size_t len;     // 出した文字数（入りきらなかった分も数える）
  FILE *fp;
} Out;

static void out_c(Out *o, int c) {
  if (o->buf) {
    if (o->len + 1 < o->n)
      o->buf[o->len] = c;
  } else {
    fputc(c, o->fp);
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
  Out o = {buf, n, 0, 0};
  format(&o, fmt, ap);
  if (n)
    buf[o.len < n ? o.len : n - 1] = 0;
  return o.len;
}

int vsprintf(char *buf, const char *fmt, va_list ap) {
  return vsnprintf(buf, 0x7fffffff, fmt, ap);
}

int vfprintf(FILE *fp, const char *fmt, va_list ap) {
  Out o = {0, 0, 0, fp};
  return format(&o, fmt, ap);
}

int vprintf(const char *fmt, va_list ap) {
  return vfprintf(stdout, fmt, ap);
}

int fprintf(FILE *fp, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vfprintf(fp, fmt, ap);
  va_end(ap);
  return n;
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
