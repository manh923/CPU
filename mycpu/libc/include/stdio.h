#ifndef __STDIO_H
#define __STDIO_H

#include <stddef.h>
#include <stdarg.h>

#define EOF (-1)
#define BUFSIZ 512
#define FILENAME_MAX 13          // MyDOS は 8.3 の名前だけ（長い名前・ディレクトリ付きは libc が縮める）
#define FOPEN_MAX 4              // MyDOS が同時に開けるファイルの数
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

// MyDOS のファイル（libc/stdio.c）。stdin はキーボード（1 行ずつ）、stdout・stderr は画面
typedef struct __FILE {
  int fd;                        // MyDOS のハンドル。-1 = 画面、-2 = キーボード
  int mode;                      // 'r' = 読む、'w' = 書く
  int eof, err;
  int ungot;                     // ungetc した文字（-1 = なし）
  unsigned char *buf;            // BUFSIZ バイト
  int pos, len;                  // 読む：buf の中の位置と長さ。書く：たまった長さ（pos）
  char **mbuf;                   // open_memstream：知らせる先（fd = -3。buf は大きくしていく、len は確保した大きさ）
  size_t *msize;
} FILE;

extern FILE *stdin, *stdout, *stderr;

FILE *fopen(const char *name, const char *mode);
FILE *open_memstream(char **bufp, size_t *sizep);
int fclose(FILE *fp);
size_t fread(void *p, size_t size, size_t n, FILE *fp);
size_t fwrite(const void *p, size_t size, size_t n, FILE *fp);
int fgetc(FILE *fp);
int getc(FILE *fp);
int fputc(int c, FILE *fp);
int putc(int c, FILE *fp);
char *fgets(char *s, int n, FILE *fp);
int fputs(const char *s, FILE *fp);
int ungetc(int c, FILE *fp);
int fflush(FILE *fp);
int feof(FILE *fp);
int ferror(FILE *fp);
void clearerr(FILE *fp);
int fseek(FILE *fp, long off, int whence);
long ftell(FILE *fp);
void rewind(FILE *fp);
int fileno(FILE *fp);
int setvbuf(FILE *fp, char *buf, int mode, size_t size);
int remove(const char *name);
int rename(const char *from, const char *to);
void perror(const char *s);

int putchar(int c);
int puts(const char *s);
int getchar(void);
int printf(const char *fmt, ...);
int fprintf(FILE *fp, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int snprintf(char *buf, size_t n, const char *fmt, ...);
int vprintf(const char *fmt, va_list ap);
int vfprintf(FILE *fp, const char *fmt, va_list ap);
int vsprintf(char *buf, const char *fmt, va_list ap);
int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap);

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

#endif
