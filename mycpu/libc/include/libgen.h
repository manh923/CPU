#ifndef __LIBGEN_H
#define __LIBGEN_H

// パスのディレクトリ部分と名前の部分（/ と \ で区切る。引数を書き換えることがある）。libc/posix.c
char *dirname(char *path);
char *basename(char *path);

#endif
