#ifndef __MYCPU_H
#define __MYCPU_H

// MyDOS の SYSCALL（番号は disk/mydos.sys.asm の先頭）
int __syscall(int n, int a, int b, int c);

#define SYS_EXIT    0
#define SYS_PUTC    1
#define SYS_PUTS    2
#define SYS_GETC    3
#define SYS_GETLINE 4
#define SYS_CLS     5
#define SYS_PUTDEC  6
#define SYS_PUTHEX  7
#define SYS_PUTG    8
#define SYS_SETATTR 9
#define SYS_KBHIT   10
#define SYS_GOTOXY  11
#define SYS_GETXY   12
#define SYS_OPEN    16
#define SYS_CLOSE   17
#define SYS_READ    18
#define SYS_WRITE   19
#define SYS_DELETE  20
#define SYS_RENAME  21
#define SYS_SEEK    22

#endif
