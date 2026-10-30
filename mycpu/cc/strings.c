#include "chibicc.h"

// 捨てないもの（トークン・ノード・型・変数など）を確保する。0 で埋めてある。
// 64KB ずつまとめて取って切り分けるので、malloc の頭（4 バイト）と切り上げの分がいらない（MyCPU はメモリが 8MB）
#ifdef __MYCPU__
#define ARENA_ALIGN 4
#define ARENA_CHUNK (65536 - 16)   // libc の malloc のちょうど 64KB の箱に入る大きさ
#else
#define ARENA_ALIGN 16
#define ARENA_CHUNK (1 << 20)
#endif

void *arena_alloc(size_t size) {
  static char *p, *end;
  size = (size + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);
  if (size > 1024)
    return calloc(1, size);
  if (end - p < (long)size) {
    p = calloc(1, ARENA_CHUNK);
    end = p + ARENA_CHUNK;
  }
  void *r = p;
  p += size;
  return r;
}

void strarray_push(StringArray *arr, char *s) {
  if (!arr->data) {
    arr->data = calloc(8, sizeof(char *));
    arr->capacity = 8;
  }

  if (arr->capacity == arr->len) {
    arr->data = realloc(arr->data, sizeof(char *) * arr->capacity * 2);
    arr->capacity *= 2;
    for (int i = arr->len; i < arr->capacity; i++)
      arr->data[i] = NULL;
  }

  arr->data[arr->len++] = s;
}

// Takes a printf-style format string and returns a formatted string.
char *format(char *fmt, ...) {
#ifdef __MYCPU__
  // MyCPU：長さを測ってから、ちょうどの大きさで確保する（メモリが少ないので）
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(NULL, 0, fmt, ap);
  va_end(ap);
  char *buf = malloc(n + 1);
  va_start(ap, fmt);
  vsnprintf(buf, n + 1, fmt, ap);
  va_end(ap);
  return buf;
#else
  char *buf;
  size_t buflen;
  FILE *out = open_memstream(&buf, &buflen);

  va_list ap;
  va_start(ap, fmt);
  vfprintf(out, fmt, ap);
  va_end(ap);
  fclose(out);
  return buf;
#endif
}
