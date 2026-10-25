#ifndef __STDARG_H
#define __STDARG_H

// MyCPU：可変長引数（cc/codegen.c の __va_area__ と同じ形）
//   レジスタで渡された引数（r16〜r21）は 8 バイトずつ並べて置いてあり、その後はスタックで渡されたもの
typedef struct {
  unsigned int gp_offset;      // 次に読むレジスタの引数（0〜48 バイト）
  void *overflow_arg_area;     // 次に読むスタックの引数
  void *reg_save_area;         // レジスタの引数の置き場
} __va_elem;

typedef __va_elem va_list[1];

#define va_start(ap, last) \
  do { *(ap) = *(__va_elem *)__va_area__; } while (0)

#define va_end(ap)

static void *__va_arg(__va_elem *ap, int sz) {
  void *r;
  if (sz <= 4 && ap->gp_offset < 48) {
    r = (char *)ap->reg_save_area + ap->gp_offset;
    ap->gp_offset += 8;
    return r;
  }
  r = ap->overflow_arg_area;
  ap->overflow_arg_area = (char *)ap->overflow_arg_area + (sz + 7) / 8 * 8;
  return r;
}

#define va_arg(ap, ty) (*(ty *)__va_arg(ap, sizeof(ty)))

#define va_copy(dest, src) ((dest)[0] = (src)[0])

#define __GNUC_VA_LIST 1
typedef va_list __gnuc_va_list;

#endif
