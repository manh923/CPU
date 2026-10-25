// 文字列とメモリ
#include <string.h>
#include <stdlib.h>

size_t strlen(const char *s) {
  const char *p = s;
  while (*p)
    p++;
  return p - s;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
  for (; n; n--, a++, b++) {
    if (*a != *b)
      return (unsigned char)*a - (unsigned char)*b;
    if (!*a)
      return 0;
  }
  return 0;
}

char *strcpy(char *dst, const char *src) {
  char *d = dst;
  while ((*d++ = *src++))
    ;
  return dst;
}

char *strncpy(char *dst, const char *src, size_t n) {
  size_t i = 0;
  for (; i < n && src[i]; i++)
    dst[i] = src[i];
  for (; i < n; i++)
    dst[i] = 0;
  return dst;
}

char *strcat(char *dst, const char *src) {
  strcpy(dst + strlen(dst), src);
  return dst;
}

char *strncat(char *dst, const char *src, size_t n) {
  char *d = dst + strlen(dst);
  while (n-- && *src)
    *d++ = *src++;
  *d = 0;
  return dst;
}

char *strchr(const char *s, int c) {
  for (;; s++) {
    if (*s == (char)c)
      return (char *)s;
    if (!*s)
      return 0;
  }
}

char *strrchr(const char *s, int c) {
  const char *r = 0;
  for (;; s++) {
    if (*s == (char)c)
      r = s;
    if (!*s)
      return (char *)r;
  }
}

char *strstr(const char *s, const char *t) {
  size_t n = strlen(t);
  for (; *s; s++)
    if (!strncmp(s, t, n))
      return (char *)s;
  return n ? 0 : (char *)s;
}

char *strdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = malloc(n);
  if (p)
    memcpy(p, s, n);
  return p;
}

void *memcpy(void *dst, const void *src, size_t n) {
  char *d = dst;
  const char *s = src;
  // どちらも 4 バイト境界なら 4 バイトずつ
  if ((((unsigned)d | (unsigned)s) & 3) == 0) {
    for (; n >= 4; n -= 4, d += 4, s += 4)
      *(unsigned *)d = *(const unsigned *)s;
  }
  while (n--)
    *d++ = *s++;
  return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
  char *d = dst;
  const char *s = src;
  if (d <= s || d >= s + n)
    return memcpy(dst, src, n);
  while (n--)
    d[n] = s[n];
  return dst;
}

void *memset(void *p, int c, size_t n) {
  unsigned char *d = p;
  while (n--)
    *d++ = c;
  return p;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = a, *y = b;
  for (; n; n--, x++, y++)
    if (*x != *y)
      return *x - *y;
  return 0;
}

void *memchr(const void *s, int c, size_t n) {
  const unsigned char *p = s;
  for (; n; n--, p++)
    if (*p == (unsigned char)c)
      return (void *)p;
  return 0;
}
