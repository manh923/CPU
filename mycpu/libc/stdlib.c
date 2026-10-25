// 標準ライブラリ：終了・メモリ（プログラムの後ろからスタックの手前まで）・数の変換・並べ替え
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <mycpu.h>

void exit(int status) {
  __syscall(SYS_EXIT, status, 0, 0);
  for (;;)
    ;
}

void abort(void) {
  __syscall(SYS_PUTS, (int)"abort\n", 0, 0);
  exit(1);
}

// malloc：プログラムの後ろ（__heap_start。tools/cc.js が置く）から確保する。
// 各ブロックの前に大きさ（4 バイト）を置き、free したものは大きさごとの連結リストで使い回す
extern char __heap_start[];
static char *heap_top;
static void *free_list[32];          // 8 × 2^k バイトのブロック

static int size_class(size_t size) {
  int k = 0;
  while (((size_t)8 << k) < size + 4)
    k++;
  return k;
}

void *malloc(size_t size) {
  int k = size_class(size);
  if (k >= 32)
    return 0;
  if (free_list[k]) {
    void *p = free_list[k];
    free_list[k] = *(void **)p;
    return p;
  }
  if (!heap_top)
    heap_top = (char *)(((unsigned)__heap_start + 7) & ~7);
  char *sp_guess = (char *)&k - 65536;          // スタックのために 64KB 空けておく
  size_t bytes = (size_t)8 << k;
  if (heap_top + bytes > sp_guess)
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
  size_t have = ((size_t)8 << k) - 4;
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

int atoi(const char *s) { return (int)strtol(s, 0, 10); }
long atol(const char *s) { return strtol(s, 0, 10); }

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
