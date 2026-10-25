#ifndef __CTYPE_H
#define __CTYPE_H

// 文字の種類（libc/ctype.c の表を引く。添字は (unsigned char)c なので、負の char を渡しても表の外は読まない。
// EOF は 255 になるが、255 はどの種類でもないので結果は同じ）
#define _CT_U 1
#define _CT_L 2
#define _CT_D 4
#define _CT_S 8
#define _CT_P 16
#define _CT_C 32
#define _CT_X 64
#define _CT_PR 128

extern const unsigned char __mycpu_ctype[256];

int isdigit(int c);
int isupper(int c);
int islower(int c);
int isalpha(int c);
int isalnum(int c);
int isxdigit(int c);
int isspace(int c);
int isprint(int c);
int isgraph(int c);
int ispunct(int c);
int iscntrl(int c);
int toupper(int c);
int tolower(int c);

#define isdigit(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_D)
#define isupper(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_U)
#define islower(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_L)
#define isalpha(c) (__mycpu_ctype[(unsigned char)(c)] & (_CT_U | _CT_L))
#define isalnum(c) (__mycpu_ctype[(unsigned char)(c)] & (_CT_U | _CT_L | _CT_D))
#define isxdigit(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_X)
#define isspace(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_S)
#define isprint(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_PR)
#define isgraph(c) (__mycpu_ctype[(unsigned char)(c)] & (_CT_U | _CT_L | _CT_D | _CT_P))
#define ispunct(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_P)
#define iscntrl(c) (__mycpu_ctype[(unsigned char)(c)] & _CT_C)

#endif
