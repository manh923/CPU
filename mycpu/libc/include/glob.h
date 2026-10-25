#ifndef __GLOB_H
#define __GLOB_H

// glob は何も見つけない（libc/posix.c）
#include <stddef.h>

typedef struct {
  size_t gl_pathc;
  char **gl_pathv;
  size_t gl_offs;
} glob_t;

#define GLOB_NOMATCH 3

int glob(const char *pattern, int flags, int (*errfunc)(const char *, int), glob_t *g);
void globfree(glob_t *g);

#endif
