#ifndef __SYS_WAIT_H
#define __SYS_WAIT_H

#include <sys/types.h>

pid_t wait(int *status);                // MyDOS には子プロセスがないので、いつも -1

#define WIFEXITED(s) 1
#define WEXITSTATUS(s) ((s) & 0xff)

#endif
