#ifndef __STDLIB_H
#define __STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff

void exit(int status);
int atexit(void (*fn)(void));
char *getenv(const char *name);
int mkstemp(char *tmpl);                        // libc/posix.c（いつも失敗）
void abort(void);
void *malloc(size_t size);
void *calloc(size_t n, size_t size);
void *realloc(void *p, size_t size);
void free(void *p);
int abs(int n);
long labs(long n);
int atoi(const char *s);
long atol(const char *s);
long strtol(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
long long strtoll(const char *s, char **end, int base);
unsigned long long strtoull(const char *s, char **end, int base);
long long atoll(const char *s);
double strtod(const char *s, char **end);        // libc/fltio.c（正しく丸める）
float strtof(const char *s, char **end);
long double strtold(const char *s, char **end);
double atof(const char *s);
int rand(void);
void srand(unsigned seed);
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));

#endif
