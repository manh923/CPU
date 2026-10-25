// 文字列とメモリ
#include <string.h>
#include <stdlib.h>
#include <errno.h>

// memcpy・memset・memchr・memcmp・strlen・strcmp・strncmp は libc/string.s（アセンブリ）

int errno;

char *strerror(int e) {
  switch (e) {
  case 0: return "No error";
  case EPERM: return "Operation not permitted";
  case ENOENT: return "File not found";
  case EIO: return "Disk error";
  case EBADF: return "Bad file handle";
  case ENOMEM: return "Out of memory";
  case EACCES: return "Access denied";
  case EEXIST: return "File exists";
  case EINVAL: return "Invalid argument";
  case EMFILE: return "Too many open files";
  case ENOSPC: return "Disk full";
  case EDOM: return "Domain error";
  case ERANGE: return "Result out of range";
  case ECHILD: return "No child process";
  case ENOSYS: return "Not supported";
  }
  return "Unknown error";
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

void *memmove(void *dst, const void *src, size_t n) {
  char *d = dst;
  const char *s = src;
  if (d <= s || d >= s + n)
    return memcpy(dst, src, n);
  while (n--)
    d[n] = s[n];
  return dst;
}

size_t strnlen(const char *s, size_t n) {
  size_t i = 0;
  while (i < n && s[i])
    i++;
  return i;
}

char *strndup(const char *s, size_t n) {
  n = strnlen(s, n);
  char *p = malloc(n + 1);
  if (p) {
    memcpy(p, s, n);
    p[n] = 0;
  }
  return p;
}

size_t strspn(const char *s, const char *accept) {
  size_t n = 0;
  while (s[n] && strchr(accept, s[n]))
    n++;
  return n;
}

size_t strcspn(const char *s, const char *reject) {
  size_t n = 0;
  while (s[n] && !strchr(reject, s[n]))
    n++;
  return n;
}

char *strpbrk(const char *s, const char *accept) {
  s += strcspn(s, accept);
  return *s ? (char *)s : 0;
}

char *strtok(char *s, const char *delim) {
  static char *next;
  if (!s)
    s = next;
  if (!s)
    return 0;
  s += strspn(s, delim);
  if (!*s) {
    next = 0;
    return 0;
  }
  char *end = s + strcspn(s, delim);
  if (*end)
    *end++ = 0;
  else
    end = 0;
  next = end;
  return s;
}
