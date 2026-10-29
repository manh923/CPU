// 標準ライブラリ：終了・メモリ（プログラムの後ろからスタックの手前まで）・数の変換・並べ替え
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <mycpu.h>

// atexit で登録した関数を、登録の逆順に呼んでから終わる
static void (*exit_funcs[32])(void);
static int n_exit_funcs;

int atexit(void (*fn)(void)) {
  if (n_exit_funcs == 32)
    return -1;
  exit_funcs[n_exit_funcs++] = fn;
  return 0;
}

void _exit(int status) {
  __syscall(SYS_EXIT, status, 0, 0);
  for (;;)
    ;
}

void exit(int status) {
  while (n_exit_funcs > 0)
    exit_funcs[--n_exit_funcs]();
  _exit(status);
}

char *getenv(const char *name) { return 0; }   // MyDOS には環境変数がない

void abort(void) {
  __syscall(SYS_PUTS, (int)"abort\n", 0, 0);
  exit(1);
}

// malloc：プログラムの後ろ（___heap_start。リンクの最後に置かれ、crt0.s → __start が __mycpu_heap に入れる）から確保する。
// 各ブロックの前に大きさの番号 k（4 バイト）を置き、free したものは番号ごとの連結リストで使い回す。
//   k = 0〜63：8 × (k + 1) バイト（512 バイトまでは 8 バイト刻み。小さいものをたくさん作るプログラムでも無駄が少ない）
//   k = 64〜 ：512 × 2^(k − 63) バイト（大きいものは 2 倍ずつ。realloc で大きくしていくものは使い回しやすい）
char *__mycpu_heap;
static char *heap_top;
static void *free_list[96];

static size_t class_bytes(int k) {
  return k < 64 ? (size_t)8 * (k + 1) : (size_t)512 << (k - 63);
}

static int size_class(size_t size) {
  size_t total = (size + 4 + 7) & ~(size_t)7;
  if (total <= 512)
    return total / 8 - 1;
  int k = 64;
  while (class_bytes(k) < total)
    k++;
  return k;
}

void *malloc(size_t size) {
  if (size > 0x7FFFFFF0)
    return 0;
  int k = size_class(size);
  if (free_list[k]) {
    void *p = free_list[k];
    free_list[k] = *(void **)p;
    return p;
  }
  if (!heap_top)
    heap_top = (char *)(((unsigned)__mycpu_heap + 7) & ~7);
  char *sp_guess = (char *)&k - 65536;          // スタックのために 64KB 空けておく
  size_t bytes = class_bytes(k);
  if (heap_top > sp_guess || bytes > (size_t)(sp_guess - heap_top))
    return 0;
  char *p = heap_top;
  heap_top += bytes;
  *(int *)p = k;
  return p + 4;
}

void free(void *p) {
  if (!p)
    return;
  int k = *(int *)((char *)p - 4);
  *(void **)p = free_list[k];
  free_list[k] = p;
}

void *calloc(size_t n, size_t size) {
  void *p = malloc(n * size);
  if (p)
    memset(p, 0, n * size);
  return p;
}

void *realloc(void *p, size_t size) {
  if (!p)
    return malloc(size);
  int k = *(int *)((char *)p - 4);
  size_t have = class_bytes(k) - 4;
  if (size <= have)
    return p;
  void *q = malloc(size);
  if (q) {
    memcpy(q, p, have);
    free(p);
  }
  return q;
}

int abs(int n) { return n < 0 ? -n : n; }
long labs(long n) { return n < 0 ? -n : n; }

unsigned long strtoul(const char *s, char **end, int base) {
  while (isspace(*s))
    s++;
  int neg = 0;
  if (*s == '+' || *s == '-')
    neg = *s++ == '-';
  if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    s += 2;
    base = 16;
  } else if (base == 0) {
    base = *s == '0' ? 8 : 10;
  }
  unsigned long v = 0;
  for (;; s++) {
    int d;
    if (isdigit(*s)) d = *s - '0';
    else if (isalpha(*s)) d = tolower(*s) - 'a' + 10;
    else break;
    if (d >= base)
      break;
    v = v * base + d;
  }
  if (end)
    *end = (char *)s;
  return neg ? -v : v;
}

long strtol(const char *s, char **end, int base) {
  return (long)strtoul(s, end, base);
}

// 64bit 版（long は 4 バイトなので、strtoul では 32bit を超える数が読めない）
unsigned long long strtoull(const char *s, char **end, int base) {
  while (isspace(*s))
    s++;
  int neg = 0;
  if (*s == '+' || *s == '-')
    neg = *s++ == '-';
  if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    s += 2;
    base = 16;
  } else if (base == 0) {
    base = *s == '0' ? 8 : 10;
  }
  unsigned long long v = 0;
  for (;; s++) {
    int d;
    if (isdigit(*s)) d = *s - '0';
    else if (isalpha(*s)) d = tolower(*s) - 'a' + 10;
    else break;
    if (d >= base)
      break;
    v = v * base + d;
  }
  if (end)
    *end = (char *)s;
  return neg ? -v : v;
}

long long strtoll(const char *s, char **end, int base) {
  return (long long)strtoull(s, end, base);
}

int atoi(const char *s) { return (int)strtol(s, 0, 10); }
long atol(const char *s) { return strtol(s, 0, 10); }
long long atoll(const char *s) { return strtoll(s, 0, 10); }

static unsigned rand_state = 1;
void srand(unsigned seed) { rand_state = seed; }
int rand(void) {
  rand_state = rand_state * 1103515245 + 12345;
  return (rand_state >> 1) & RAND_MAX;
}

// 並べ替え（挿入ソート。小さい配列向け。大きいものは後で）
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
  char *a = base;
  char tmp[256];
  if (size > sizeof(tmp))
    return;
  for (size_t i = 1; i < n; i++) {
    memcpy(tmp, a + i * size, size);
    size_t j = i;
    while (j > 0 && cmp(a + (j - 1) * size, tmp) > 0) {
      memcpy(a + j * size, a + (j - 1) * size, size);
      j--;
    }
    memcpy(a + j * size, tmp, size);
  }
}
