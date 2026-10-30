#ifndef __SYS_STAT_H
#define __SYS_STAT_H

// stat はファイルがあるかと大きさだけ（MyDOS には時刻がないので st_mtime は 0）。libc/posix.c
#include <sys/types.h>

struct stat {
  off_t st_size;
  time_t st_mtime;
  mode_t st_mode;
};

#define S_IFMT 0170000
#define S_IFREG 0100000
#define S_IFDIR 0040000
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)

int stat(const char *name, struct stat *st);
int mkdir(const char *path, mode_t mode);      // MyDOS の SYSCALL 23（mode は使わない）

#endif
