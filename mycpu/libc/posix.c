// POSIX のほんの一部（unistd.h・sys/stat.h・glob.h・libgen.h・strings.h）。chibicc を MyDOS で動かすため。
// MyDOS にはプロセスがないので、fork などは「いつも失敗する」だけ。ディレクトリ（mkdir・chdir など）は MyDOS の SYSCALL で
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <glob.h>
#include <libgen.h>
#include <strings.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <ctype.h>
#include <string.h>
#include <mycpu.h>

// MyDOS のエラー（負の数）→ errno
static int dos_err(int r) {
  static int map[] = {0, EBADF, ENOENT, EMFILE, ENOSPC, EACCES, EINVAL, EIO};
  errno = (r < 0 && r >= -7) ? map[-r] : EIO;
  return -1;
}

static int dir_call(int n, const char *path) {
  char name[DOSPATH];
  int r = __syscall(n, (int)__mycpu_dosname(path, name), 0, 0);
  return r < 0 ? dos_err(r) : 0;
}

int mkdir(const char *path, mode_t mode) { return dir_call(SYS_MKDIR, path); }
int rmdir(const char *path) { return dir_call(SYS_RMDIR, path); }
int chdir(const char *path) { return dir_call(SYS_CHDIR, path); }

// 今のディレクトリ（"C:\INCLUDE" のように）。buf が NULL なら malloc する
char *getcwd(char *buf, size_t size) {
  char tmp[DOSPATH];
  int r = __syscall(SYS_GETCWD, (int)tmp, sizeof(tmp), 0);
  if (r < 0) {
    errno = EIO;
    return 0;
  }
  if (!buf) {
    size = size > (size_t)r ? size : (size_t)r + 1;
    buf = malloc(size);
    if (!buf) {
      errno = ENOMEM;
      return 0;
    }
  }
  if ((size_t)r + 1 > size) {
    errno = ERANGE;
    return 0;
  }
  memcpy(buf, tmp, r + 1);
  return buf;
}

// 大きさを知るために開いて終わりまで seek する
int stat(const char *name, struct stat *st) {
  FILE *fp = fopen(name, "r");
  if (!fp)
    return -1;
  fseek(fp, 0, SEEK_END);
  st->st_size = ftell(fp);
  st->st_mtime = 0;
  st->st_mode = S_IFREG | 0644;
  fclose(fp);
  return 0;
}

int access(const char *name, int mode) {
  struct stat st;
  return stat(name, &st);
}

int unlink(const char *name) { return remove(name); }
int close(int fd) { return 0; }        // fopen した FILE は fclose で閉じる
int isatty(int fd) { return fd <= 2; }
pid_t getpid(void) { return 1; }

pid_t fork(void) {
  errno = ENOSYS;
  return -1;
}

int execvp(const char *file, char *const argv[]) {
  errno = ENOSYS;
  return -1;
}

pid_t wait(int *status) {
  errno = ECHILD;
  return -1;
}

int glob(const char *pattern, int flags, int (*errfunc)(const char *, int), glob_t *g) {
  g->gl_pathc = 0;
  g->gl_pathv = 0;
  return GLOB_NOMATCH;
}

void globfree(glob_t *g) {}

static int is_sep(char c) { return c == '/' || c == '\\'; }

char *dirname(char *path) {
  if (!path || !*path)
    return ".";
  char *end = path + strlen(path) - 1;
  while (end > path && is_sep(*end))   // 末尾の / を除く
    end--;
  while (end >= path && !is_sep(*end))
    end--;
  if (end < path)
    return ".";
  while (end > path && is_sep(*end))
    end--;
  end[1] = 0;
  return path;
}

char *basename(char *path) {
  if (!path || !*path)
    return ".";
  char *end = path + strlen(path) - 1;
  while (end > path && is_sep(*end))
    *end-- = 0;
  char *p = end;
  while (p > path && !is_sep(p[-1]))
    p--;
  return p;
}

int strcasecmp(const char *a, const char *b) {
  for (;; a++, b++) {
    int c = tolower((unsigned char)*a), d = tolower((unsigned char)*b);
    if (c != d || !c)
      return c - d;
  }
}

int strncasecmp(const char *a, const char *b, size_t n) {
  for (; n; n--, a++, b++) {
    int c = tolower((unsigned char)*a), d = tolower((unsigned char)*b);
    if (c != d || !c)
      return c - d;
  }
  return 0;
}

int mkstemp(char *tmpl) {
  errno = ENOSYS;
  return -1;
}
