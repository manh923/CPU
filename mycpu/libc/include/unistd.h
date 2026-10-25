#ifndef __UNISTD_H
#define __UNISTD_H

// POSIX のほんの一部（libc/posix.c）。MyDOS にはプロセスがないので、fork・exec などはいつも失敗する
#include <sys/types.h>

int close(int fd);
int unlink(const char *name);
int access(const char *name, int mode);
int isatty(int fd);
pid_t fork(void);
int execvp(const char *file, char *const argv[]);
void _exit(int status);
pid_t getpid(void);

#define F_OK 0
#define R_OK 4
#define W_OK 2
#define X_OK 1

#endif
