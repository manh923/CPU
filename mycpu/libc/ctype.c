// 文字の種類（ctype.h）：表を引く（添字は (unsigned char)c）
// （chibicc はインライン展開をしないので、関数にすると 1 文字ごとに何回も呼び出しになって遅い）
#include <ctype.h>

#undef isdigit
#undef isupper
#undef islower
#undef isalpha
#undef isalnum
#undef isxdigit
#undef isspace
#undef isprint
#undef isgraph
#undef ispunct
#undef iscntrl

const unsigned char __mycpu_ctype[256] = {
  32, 32, 32, 32, 32, 32, 32, 32, 32, 40, 40, 40, 40, 40, 32, 32,
  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
  136, 144, 144, 144, 144, 144, 144, 144, 144, 144, 144, 144, 144, 144, 144, 144,
  196, 196, 196, 196, 196, 196, 196, 196, 196, 196, 144, 144, 144, 144, 144, 144,
  144, 193, 193, 193, 193, 193, 193, 129, 129, 129, 129, 129, 129, 129, 129, 129,
  129, 129, 129, 129, 129, 129, 129, 129, 129, 129, 129, 144, 144, 144, 144, 144,
  144, 194, 194, 194, 194, 194, 194, 130, 130, 130, 130, 130, 130, 130, 130, 130,
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 144, 144, 144, 144, 32,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

// 関数の版（番地を取るときなど）
int isdigit(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_D; }
int isupper(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_U; }
int islower(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_L; }
int isalpha(int c) { return __mycpu_ctype[(unsigned char)c] & (_CT_U | _CT_L); }
int isalnum(int c) { return __mycpu_ctype[(unsigned char)c] & (_CT_U | _CT_L | _CT_D); }
int isxdigit(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_X; }
int isspace(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_S; }
int isprint(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_PR; }
int isgraph(int c) { return __mycpu_ctype[(unsigned char)c] & (_CT_U | _CT_L | _CT_D | _CT_P); }
int ispunct(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_P; }
int iscntrl(int c) { return __mycpu_ctype[(unsigned char)c] & _CT_C; }
int toupper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
int tolower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
