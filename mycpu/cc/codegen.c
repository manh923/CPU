// コード生成：この CPU（isa-spec.md、32bit）のアセンブリを出す。元の chibicc は x86-64 向け。
//
// 作りは元の「スタックマシン」に、レジスタの割り当てを足したもの：
//   式の値は r16 に置く（long long・double は r16・r17）。r17〜r22 は作業用、r31 = フレームポインタ（x86 の rbp）
//   r24〜r30（呼ばれた側が保存する）は、関数ごとに
//     ・よく使うスカラーのローカル変数（番地を取らない 4 バイト以下の整数・ポインタ・float）を r24 から最大 5 個
//     ・残りを、式の途中の値の一時置き場（x86 なら push するところ）に r30 から
//   一時置き場が足りなければスタックに積む（8 バイトずつ）。使ったものだけを関数の入口で保存する。
//   式は「値を入れるレジスタ」を指定して作る（gen_to）。定数・レジスタの変数・4 バイトのメモリの変数は、
//   命令の即値・レジスタ・メモリの欄（I・R・M 形式）にそのまま書く。条件は比べて直接分岐する（gen_cond）。
// 型の大きさ（ILP32）：char 1、short 2、int・long・ポインタ 4、long long 8。
//   long long の値はレジスタ 2 つ（r16 = 下位、r17 = 上位）。割り算・余りは libc の __divdi3 などを呼ぶ。
//   float は 4 バイト（r16）、double・long double は 8 バイト（long long と同じく r16・r17）。どちらも IEEE 754。
//   計算・比べる・変換はどれも libc/softfloat.c の関数を呼ぶ（ソフトウェアで）。
// 呼び出し規約（isa-spec.md の 8 章）：引数は r16〜r21（7 個目からと、構造体・long long はスタック）、
//   戻り値は r16（long long・double は r16・r17）。float は int と同じ、double は long long と同じに渡す。
//   構造体を返す関数は、呼ぶ側がバッファを用意して、その番地を隠れた最初の引数として渡す。
// フレーム：[r31] = 戻り番地（lr）、[r31 + 4] = 呼んだ側の r31、[r31 + 8] 〜 = スタックで渡された引数、
//   [r31 − n] = ローカル変数、その下に保存した r24〜r30。SP は常に 8 の倍数。
//   関数を呼ばない関数は lr を保存しない。フレームの要らない関数（メモリの変数・保存するレジスタなし）は何もしない。
// 名前：C の大域の名前は「_名前」、static と内部のラベルは「L<ファイルの番号>…」（ファイルごとに別）。
//   データは「; @data」、コードは「; @text」の行で区切って出す（ドライバが分けて並べ直す）。
//   関数の前には「; @fn 名前」、大域変数の前には「; @obj 名前」（ドライバが使わないものを捨てる）。
#include "chibicc.h"

#define GP_MAX 6
#define REG_LO 24                      // 割り当てに使うレジスタ r24〜r30
#define REG_HI 30
#define VAR_MAX 5                      // 変数に使うのは最大 5 個（残りは一時置き場）
#define TSTACK_MAX 1024

static FILE *output_file;
static int depth;                      // スタックに積んでいる数（8 バイト単位）
static Obj *current_fn;
static HashMap globals;                // この翻訳単位の大域の名前 → Obj（static かどうかを知るため）
static char fid[16];                   // ファイルの番号（ファイル名のハッシュ）

// 一時置き場：積んだ値ごとに、どのレジスタか（n = 0 ならスタック）
typedef struct {
  int n;
  int r1, r2;
} Slot;
static Slot tstack[TSTACK_MAX];
static int tdepth;
static int ntregs, tused;              // 一時置き場に使えるレジスタの数（r30 から下へ）・使っている数
static unsigned used_regs;             // 使った r24〜r30（関数の入口で保存する）
static bool has_call;                  // CALL を出したか（出さなければ lr を保存しない）

static void gen_expr(Node *node);
static void gen_expr2(Node *node);
static void gen_to(Node *node, int dst);
static void gen_void(Node *node);
static void gen_stmt(Node *node);

__attribute__((format(printf, 1, 2)))
static void println(char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(output_file, fmt, ap);
  va_end(ap);
  fprintf(output_file, "\n");
}

static int count(void) {
  static int i = 1;
  return i++;
}

// C の名前をラベルに使える文字だけにする（英数字と _ 以外のバイトは「.16 進」に。日本語の識別子など）
static char *safe_name(char *name) {
  char *buf = calloc(1, strlen(name) * 3 + 1), *p = buf;
  for (unsigned char *s = (unsigned char *)name; *s; s++) {
    if (isalnum(*s) || *s == '_')
      *p++ = *s;
    else
      p += sprintf(p, ".%02X", *s);
  }
  return buf;
}

// 名前をアセンブラのラベルにする
static char *sym_name(char *name) {
  if (!strncmp(name, ".L..", 4))         // 文字列・static なローカル変数・goto のラベル
    return format("L%s..%s", fid, name + 4);
  Obj *var = hashmap_get(&globals, name);
  if (var && var->is_static)
    return format("L%s_%s", fid, safe_name(name));
  return format("_%s", safe_name(name));
}

// dst ← src（dst が負なら、値は要らないので何もしない）
static void move(int dst, int src) {
  if (dst >= 0 && dst != src)
    println("  ADDR32 r%d, r%d, r0", dst, src);
}

// ---- スタックに積む（関数の引数として渡すものなど、本当にメモリに置くもの） ----

static void push_mem(void) {
  println("  ADDI32 sp, sp, -8");
  println("  STORE32_32 r16, sp, 0");
  depth++;
}

static void pop_mem(int reg) {
  println("  LOAD32_32 r%d, sp, 0", reg);
  println("  ADDI32 sp, sp, 8");
  depth--;
}

// 64bit の値（r16 = 下位、r17 = 上位）を 1 つの 8 バイトに積む・取り出す
static void push64_mem(void) {
  println("  ADDI32 sp, sp, -8");
  println("  STORE32_32 r16, sp, 0");
  println("  STORE32_32 r17, sp, 4");
  depth++;
}

static void pop64_mem(int lo, int hi) {
  println("  LOAD32_32 r%d, sp, 0", lo);
  println("  LOAD32_32 r%d, sp, 4", hi);
  println("  ADDI32 sp, sp, 8");
  depth--;
}

// ---- 一時置き場（空いているレジスタ、なければスタック） ----

static Slot *new_slot(void) {
  if (tdepth >= TSTACK_MAX)
    error("式が深すぎる（MyCPU）");
  return &tstack[tdepth++];
}

static void push(void) {
  Slot *s = new_slot();
  if (tused < ntregs) {
    s->n = 1;
    s->r1 = REG_HI - tused++;
    used_regs |= 1u << s->r1;
    move(s->r1, 16);
    return;
  }
  s->n = 0;
  push_mem();
}

static void push64(void) {
  Slot *s = new_slot();
  if (tused + 2 <= ntregs) {
    s->n = 2;
    s->r1 = REG_HI - tused++;
    s->r2 = REG_HI - tused++;
    used_regs |= (1u << s->r1) | (1u << s->r2);
    move(s->r1, 16);
    move(s->r2, 17);
    return;
  }
  s->n = 0;
  push64_mem();
}

// 積んだ値を取り出す。レジスタにあれば、そのレジスタの番号を返す（コードは出さない。次に積む前にすぐ使うこと）。
// スタックにあれば reg に読んで reg を返す
static int pop_reg(int reg) {
  Slot *s = &tstack[--tdepth];
  if (s->n) {
    tused--;
    return s->r1;
  }
  pop_mem(reg);
  return reg;
}

static void pop(int reg) {
  move(reg, pop_reg(reg));
}

static void pop64(int lo, int hi) {
  Slot *s = &tstack[--tdepth];
  if (s->n) {
    tused -= 2;
    move(lo, s->r1);
    move(hi, s->r2);
    return;
  }
  pop64_mem(lo, hi);
}

// long long（8 バイトの整数）か
static bool is64(Type *ty) {
  return ty->kind == TY_LONG && ty->size == 8;
}

// 8 バイトのスカラー（long long・double・long double）か。レジスタ 2 つで扱う
static bool is_pair(Type *ty) {
  return is64(ty) || ty->kind == TY_DOUBLE || ty->kind == TY_LDOUBLE;
}

// レジスタ 1 つに入るスカラー（4 バイト以下の整数・ポインタ・float）か
static bool is_word(Type *ty) {
  return ty && ((is_integer(ty) && ty->size <= 4) || ty->kind == TY_PTR || ty->kind == TY_FLOAT);
}

// 32bit の整数・ポインタ（float でない）か。命令 1 つで計算・比べられる
static bool is_int32(Type *ty) {
  return is_word(ty) && ty->kind != TY_FLOAT;
}

static void push_val(Type *ty) {
  if (is_pair(ty))
    push64();
  else
    push();
}

// Round up `n` to the nearest multiple of `align`. For instance,
// align_to(5, 8) returns 8 and align_to(11, 8) returns 16.
int align_to(int n, int align) {
  return (n + align - 1) / align * align;
}

// 値（型 ty）が 0 かを r16 だけで見られるようにする（r16・r17 を壊す）。
// 浮動小数点は符号のビットを除いて見る（−0.0 も 0）。NaN は 0 でない
static void to_cmp_zero(Type *ty) {
  if (ty->kind == TY_FLOAT) {
    println("  SHLI32 r16, r16, 1");
  } else if (ty->kind == TY_DOUBLE || ty->kind == TY_LDOUBLE) {
    println("  SHLI32 r17, r17, 1");
    println("  ORR32 r16, r16, r17");
  } else if (is64(ty)) {
    println("  ORR32 r16, r16, r17");
  }
}

// libc/softfloat.c の関数を 1 つの引数で呼ぶ。引数は今の値：8 バイトならスタックで、4 バイトなら r16 で渡す
static void call_helper(char *fn, bool arg8) {
  has_call = true;
  if (arg8)
    push64_mem();
  println("  CALL32 %s", fn);
  if (arg8) {
    println("  ADDI32 sp, sp, 8");
    depth--;
  }
}

// src から dst へ size バイト写す（r19〜r22 を壊す。src・dst のレジスタは変えない）
static void copy_bytes(int dst, int dst_off, int src, int size, int align) {
  if (align >= 4 && size % 4 == 0 && size <= 128) {
    for (int i = 0; i < size; i += 4) {
      println("  LOAD32_32 r20, r%d, %d", src, i);
      println("  STORE32_32 r20, r%d, %d", dst, dst_off + i);
    }
    return;
  }
  if (align >= 4 && size % 4 == 0) {   // 4 バイトずつのループ
    int c = count();
    println("  ADDR32 r19, r%d, r0", src);
    println("  ADDI32 r20, r%d, %d", dst, dst_off);
    println("  ADDI32 r21, r19, %d", size);
    println("L%s.cp.%d:", fid, c);
    println("  LOAD32_32 r22, r19, 0");
    println("  STORE32_32 r22, r20, 0");
    println("  ADDI32 r19, r19, 4");
    println("  ADDI32 r20, r20, 4");
    println("  CMPLTUR32 p1, r19, r21");
    println("  BR32 p1, L%s.cp.%d", fid, c);
    return;
  }
  if (size <= 16) {
    for (int i = 0; i < size; i++) {
      println("  LOAD8U_32 r20, r%d, %d", src, i);
      println("  STORE8_32 r20, r%d, %d", dst, dst_off + i);
    }
    return;
  }
  int c = count();
  println("  ADDI32 r21, r0, 0");
  println("L%s.cp.%d:", fid, c);
  println("  ADDR32 r22, r%d, r21", src);
  println("  LOAD8U_32 r20, r22, 0");
  println("  ADDR32 r22, r%d, r21", dst);
  println("  STORE8_32 r20, r22, %d", dst_off);
  println("  ADDI32 r21, r21, 1");
  println("  CMPLTUI32 p1, r21, %d", size);
  println("  BR32 p1, L%s.cp.%d", fid, c);
}

// ---- 値・番地を命令の欄に書く ----

// 番地 =「レジスタ base ＋ 大域の名前 sym（なければ NULL）＋ 数 off」
typedef struct {
  int base;
  int off;
  char *sym;
} Addr;

// 命令の欄に書ける値：レジスタ・即値・メモリ（4 バイトの変数）
typedef struct {
  enum { O_REG, O_IMM, O_MEM } kind;
  int reg;
  int32_t imm;
  Addr a;
} Opnd;

static void print_reg(int r) {
  fprintf(output_file, (r >= 1 && r <= 7) ? "p%d" : "r%d", r);
}

static void print_addr(Addr *a) {
  fprintf(output_file, "r%d, ", a->base);
  if (!a->sym)
    fprintf(output_file, "%d", a->off);
  else if (a->off < 0)
    fprintf(output_file, "%s-%d", a->sym, -a->off);
  else if (a->off > 0)
    fprintf(output_file, "%s+%d", a->sym, a->off);
  else
    fprintf(output_file, "%s", a->sym);
}

// 「op rd, 番地」（ロード・ストア・ADDI）
static void emit_mem(char *op, int rd, Addr *a) {
  fprintf(output_file, "  %s ", op);
  print_reg(rd);
  fprintf(output_file, ", ");
  print_addr(a);
  fprintf(output_file, "\n");
}

// M 形式「op rd, rs1, 番地」：rd ← rs1 op [番地]（4 バイト）
static void emit_m(char *op, int rd, int rs1, Addr *a) {
  fprintf(output_file, "  %s ", op);
  print_reg(rd);
  fprintf(output_file, ", r%d, ", rs1);
  print_addr(a);
  fprintf(output_file, "\n");
}

// レジスタに置いた変数なら、そのレジスタ（なければ 0）
static int reg_var(Node *node) {
  if (node->kind == ND_VAR && node->var->is_local && node->var->reg)
    return node->var->reg;
  return 0;
}

// 何もしない変換（32bit の整数・ポインタどうしで 4 バイトへ、配列・関数からポインタへ）を外す
static Node *strip_cast(Node *node) {
  while (node->kind == ND_CAST && is_int32(node->ty) && node->ty->size == 4 && node->ty->kind != TY_BOOL &&
         (is_int32(node->lhs->ty) || node->lhs->ty->kind == TY_ARRAY || node->lhs->ty->kind == TY_FUNC))
    node = node->lhs;
  return node;
}

// 値がいつも 0 か 1 の式か（比べる・!・&&・||・_Bool）
static bool is_bool_valued(Node *node) {
  switch (node->kind) {
  case ND_EQ:
  case ND_NE:
  case ND_LT:
  case ND_LE:
  case ND_NOT:
  case ND_LOGAND:
  case ND_LOGOR:
    return true;
  }
  return node->ty->kind == TY_BOOL;
}

// 32bit の整数の定数か（usual_arith_conv が付けた型の変換もたどる）。*v にその値
static bool is_imm32(Node *node, int32_t *v) {
  // 定数の変換は、ここで計算しておく
  if (node->kind == ND_CAST && is_int32(node->ty) && is_imm32(node->lhs, v)) {
    Type *ty = node->ty;
    if (ty->kind == TY_BOOL)
      *v = *v != 0;
    else if (ty->size == 1)
      *v = ty->is_unsigned ? (int32_t)(uint8_t)*v : (int32_t)(int8_t)*v;
    else if (ty->size == 2)
      *v = ty->is_unsigned ? (int32_t)(uint16_t)*v : (int32_t)(int16_t)*v;
    return true;
  }
  // 定数どうしの計算も（-3、1 << 4 など）
  int32_t a, b;
  if (is_int32(node->ty) && (node->kind == ND_NEG || node->kind == ND_BITNOT) && is_imm32(node->lhs, &a)) {
    *v = node->kind == ND_NEG ? (int32_t)(0u - (uint32_t)a) : ~a;
    return true;
  }
  if (is_int32(node->ty) && node->rhs && is_int32(node->lhs->ty) && is_int32(node->rhs->ty) &&
      is_imm32(node->lhs, &a) && is_imm32(node->rhs, &b)) {
    uint32_t ua = a, ub = b;
    bool uns = node->ty->is_unsigned;
    switch (node->kind) {
    case ND_ADD: *v = (int32_t)(ua + ub); return true;
    case ND_SUB: *v = (int32_t)(ua - ub); return true;
    case ND_MUL: *v = (int32_t)(ua * ub); return true;
    case ND_BITAND: *v = a & b; return true;
    case ND_BITOR: *v = a | b; return true;
    case ND_BITXOR: *v = a ^ b; return true;
    case ND_SHL: *v = (int32_t)(ua << (ub & 31)); return true;
    case ND_SHR: *v = node->lhs->ty->is_unsigned ? (int32_t)(ua >> (ub & 31)) : a >> (ub & 31); return true;
    case ND_DIV:
    case ND_MOD:
      if (b == 0 || (!uns && a == INT32_MIN && b == -1))
        return false;
      if (node->kind == ND_DIV)
        *v = uns ? (int32_t)(ua / ub) : a / b;
      else
        *v = uns ? (int32_t)(ua % ub) : a % b;
      return true;
    }
  }
  if (node->kind != ND_NUM || !is_integer(node->ty) || is64(node->ty))
    return false;
  *v = (int32_t)node->val;
  return true;
}

// 番地を計算せずに書ける左辺値か（変数・レジスタの値＋定数の先・その構造体のメンバー）
static bool addr_simple(Node *node) {
  int32_t v;
  switch (node->kind) {
  case ND_VAR:
    return node->var->ty->kind != TY_VLA && !reg_var(node);
  case ND_MEMBER:
    return addr_simple(node->lhs);
  case ND_DEREF: {
    Node *p = node->lhs;
    if ((p->kind == ND_ADD || p->kind == ND_SUB) && p->ty->base && is_imm32(p->rhs, &v))
      p = p->lhs;
    return is_imm32(p, &v) || reg_var(strip_cast(p));
  }
  }
  return false;
}

static void gen_addr(Node *node);
static int gen_val(Node *node);
static bool is_cheap(Node *node);
static void gen_cheap(Node *node, int dst);
static int gen_cheap_val(Node *node, int dst);

// node（左辺値）の番地を Addr に。番地を計算するコードが要るときは、その値を r16 に置く（base = 16）
static void gen_addr_op(Node *node, Addr *a) {
  int32_t v;
  a->off = 0;
  a->sym = NULL;
  switch (node->kind) {
  case ND_VAR:
    if (node->var->ty->kind == TY_VLA)
      break;
    if (node->var->is_local) {
      if (node->var->reg)
        error_tok(node->tok, "レジスタの変数の番地（MyCPU の codegen.c の間違い）");
      a->base = 31;
      a->off = node->var->offset;
      return;
    }
    a->base = 0;
    a->sym = sym_name(node->var->name);
    return;
  case ND_MEMBER:
    gen_addr_op(node->lhs, a);
    a->off += node->member->offset;
    return;
  case ND_DEREF: {
    Node *p = node->lhs;
    int d = 0;
    if ((p->kind == ND_ADD || p->kind == ND_SUB) && p->ty->base && is_imm32(p->rhs, &v)) {
      d = p->kind == ND_ADD ? v : -v;
      p = p->lhs;
    }
    if (is_imm32(p, &v)) {
      a->base = 0;
      a->off = v + d;
      return;
    }
    a->base = gen_val(p);
    a->off = d;
    return;
  }
  }
  gen_addr(node);
  a->base = 16;
}

// 番地から型 ty の値を dst に読む（char・short は int の大きさに広げる）。配列・構造体・関数は番地そのもの
static void load_at(Type *ty, int dst, Addr *a) {
  switch (ty->kind) {
  case TY_ARRAY:
  case TY_STRUCT:
  case TY_UNION:
  case TY_FUNC:
  case TY_VLA:
    if (a->base != dst || a->off || a->sym)
      emit_mem("ADDI32", dst, a);
    return;
  }
  if (ty->size == 1) {
    emit_mem(ty->is_unsigned ? "LOAD8U_32" : "LOAD8S_32", dst, a);
  } else if (ty->size == 2) {
    emit_mem(ty->is_unsigned ? "LOAD16U_32" : "LOAD16S_32", dst, a);
  } else if (ty->size == 4) {
    emit_mem("LOAD32_32", dst, a);
  } else if (is_pair(ty)) {            // dst は r16（上位を r17 に）
    Addr hi = *a;
    hi.off += 4;
    emit_mem("LOAD32_32", 17, &hi);
    emit_mem("LOAD32_32", 16, a);
  } else {
    error("この型はまだ使えない（MyCPU）");
  }
}

// 番地へ src（型 ty。8 バイトなら src と src + 1）を書く
static void store_at(Type *ty, int src, Addr *a) {
  if (is_pair(ty)) {
    Addr hi = *a;
    hi.off += 4;
    emit_mem("STORE32_32", src, a);
    emit_mem("STORE32_32", src + 1, &hi);
    return;
  }
  if (ty->size == 1)
    emit_mem("STORE8_32", src, a);
  else if (ty->size == 2)
    emit_mem("STORE16_32", src, a);
  else if (ty->size == 4)
    emit_mem("STORE32_32", src, a);
  else
    error("この型はまだ使えない（MyCPU）");
}

// 命令 1 つの値として書けるか（定数・レジスタの変数・4 バイトのメモリの変数）。コードは出さない
static bool leaf(Node *node, Opnd *o) {
  int32_t v;
  if (is_imm32(node, &v)) {
    o->kind = O_IMM;
    o->imm = v;
    return true;
  }
  node = strip_cast(node);
  if (node->kind != ND_VAR)
    return false;
  if (reg_var(node)) {
    o->kind = O_REG;
    o->reg = node->var->reg;
    return true;
  }
  if (node->ty->size == 4 && is_word(node->ty) && node->var->ty->kind != TY_VLA) {
    o->kind = O_MEM;
    gen_addr_op(node, &o->a);
    return true;
  }
  return false;
}

// 値をレジスタに（即値・メモリなら scratch に読む。0 は r0）
static int opnd_reg(Opnd *o, int scratch) {
  switch (o->kind) {
  case O_REG:
    return o->reg;
  case O_IMM:
    if (o->imm == 0)
      return 0;
    println("  ADDI32 r%d, r0, %d", scratch, o->imm);
    return scratch;
  default:
    emit_mem("LOAD32_32", scratch, &o->a);
    return scratch;
  }
}

// 2 つの値を、命令の欄に書ける形にする。命令 1 つで書けないほうは計算する（左は r16、両方なら右は一時置き場）
static void gen_operands(Node *lhs, Node *rhs, Opnd *l, Opnd *r) {
  bool ll = leaf(lhs, l), rl = leaf(rhs, r);
  if (ll && rl)
    return;
  if (ll) {
    gen_to(rhs, 16);
    r->kind = O_REG;
    r->reg = 16;
    return;
  }
  if (rl) {
    gen_to(lhs, 16);
    l->kind = O_REG;
    l->reg = 16;
    return;
  }
  // 片方が r17 だけで求められるなら、一時置き場は要らない
  if (is_cheap(rhs)) {
    gen_to(lhs, 16);
    l->kind = r->kind = O_REG;
    l->reg = 16;
    r->reg = gen_cheap_val(rhs, 17);
    return;
  }
  if (is_cheap(lhs)) {
    gen_to(rhs, 16);
    l->kind = r->kind = O_REG;
    r->reg = 16;
    l->reg = gen_cheap_val(lhs, 17);
    return;
  }
  gen_to(rhs, 16);
  push();
  gen_to(lhs, 16);
  l->kind = O_REG;
  l->reg = 16;
  r->kind = O_REG;
  r->reg = pop_reg(17);
}

// Compute the absolute address of a given node.
// It's an error if a given node does not reside in memory.
static void gen_addr(Node *node) {
  Addr a;
  switch (node->kind) {
  case ND_VAR:
    // Variable-length array, which is always local.
    if (node->var->ty->kind == TY_VLA) {
      println("  LOAD32_32 r16, r31, %d", node->var->offset);
      return;
    }
    gen_addr_op(node, &a);
    emit_mem("ADDI32", 16, &a);
    return;
  case ND_DEREF:
    gen_expr(node->lhs);
    return;
  case ND_COMMA:
    gen_void(node->lhs);
    gen_addr(node->rhs);
    return;
  case ND_MEMBER:
    gen_addr(node->lhs);
    if (node->member->offset)
      println("  ADDI32 r16, r16, %d", node->member->offset);
    return;
  case ND_FUNCALL:
    if (node->ret_buffer) {
      gen_expr(node);
      return;
    }
    break;
  case ND_ASSIGN:
  case ND_COND:
    if (node->ty->kind == TY_STRUCT || node->ty->kind == TY_UNION) {
      gen_expr(node);
      return;
    }
    break;
  case ND_VLA_PTR:
    println("  ADDI32 r16, r31, %d", node->var->offset);
    return;
  }

  error_tok(node->tok, "not an lvalue");
}

// Load a value from where r16 is pointing to.
static void load(Node *node, Type *ty) {
  Addr a = {16, 0, NULL};
  load_at(ty, 16, &a);
}

static void cast(Node *node, Type *from, Type *to);

// 浮動小数点が入る変換（libc/softfloat.c の関数を呼ぶ）
static void cast_flonum(Node *node, Type *from, Type *to) {
  bool f32 = from->kind == TY_FLOAT, t32 = to->kind == TY_FLOAT;

  if (is_flonum(from) && is_flonum(to)) {
    if (f32 && !t32)
      call_helper("___extendsfdf2", false);
    else if (!f32 && t32)
      call_helper("___truncdfsf2", true);
    return;                            // double と long double は同じ
  }

  // 整数 → 浮動小数点（char・short・_Bool は int に広げてあるので int として）
  if (is_flonum(to)) {
    char *fn;
    if (is64(from))
      fn = from->is_unsigned ? (t32 ? "___floatundisf" : "___floatundidf") : (t32 ? "___floatdisf" : "___floatdidf");
    else if (from->size == 4 && (from->is_unsigned || from->base))
      fn = t32 ? "___floatunsisf" : "___floatunsidf";
    else
      fn = t32 ? "___floatsisf" : "___floatsidf";
    call_helper(fn, is64(from));
    return;
  }

  // 浮動小数点 → 整数：まず int・unsigned・long long・unsigned long long のどれかにして、小さい型へは切り詰める
  char *fn;
  if (is64(to))
    fn = to->is_unsigned ? (f32 ? "___fixunssfdi" : "___fixunsdfdi") : (f32 ? "___fixsfdi" : "___fixdfdi");
  else if (to->size == 4 && to->is_unsigned)
    fn = f32 ? "___fixunssfsi" : "___fixunsdfsi";
  else
    fn = f32 ? "___fixsfsi" : "___fixdfsi";
  call_helper(fn, !f32);
  if (!is64(to) && to->size < 4)
    cast(node, ty_int, to);
}

// 32bit の整数どうしの変換：src を変換して dst に。小さい型へは切り詰めて広げ直す
// （読むときに広げてあるので、大きい型へは何もしない）
static void cast_int(Type *from, Type *to, int dst, int src) {
  if (to->kind == TY_BOOL) {
    println("  CMPNEI32 p1, r%d, 0", src);
    println("  BTOI32 r%d, p1", dst);
    return;
  }
  if (to->size == 1 && !(from->size == 1 && from->is_unsigned == to->is_unsigned)) {
    if (to->is_unsigned) {
      println("  ANDI32 r%d, r%d, 0xFF", dst, src);
    } else {
      println("  SHLI32 r%d, r%d, 24", dst, src);
      println("  SARI32 r%d, r%d, 24", dst, dst);
    }
  } else if (to->size == 2 && from->size > 1 && !(from->size == 2 && from->is_unsigned == to->is_unsigned)) {
    if (to->is_unsigned) {
      println("  ANDI32 r%d, r%d, 0xFFFF", dst, src);
    } else {
      println("  SHLI32 r%d, r%d, 16", dst, src);
      println("  SARI32 r%d, r%d, 16", dst, dst);
    }
  } else if (to->size == 2 && from->size == 1 && to->is_unsigned && !from->is_unsigned) {
    println("  ANDI32 r%d, r%d, 0xFFFF", dst, src);
  } else {
    move(dst, src);
  }
}

static void cast(Node *node, Type *from, Type *to) {
  if (to->kind == TY_VOID)
    return;

  if (to->kind == TY_BOOL) {
    to_cmp_zero(from);
    println("  CMPNEI32 p1, r16, 0");
    println("  BTOI32 r16, p1");
    return;
  }

  if (is_flonum(from) || is_flonum(to)) {
    cast_flonum(node, from, to);
    return;
  }

  // long long へ：上位を、符号付きなら符号で、符号なし・ポインタなら 0 で埋める
  if (is64(to)) {
    if (!is64(from)) {
      if (from->is_unsigned || from->base || from->kind == TY_BOOL)
        println("  ADDI32 r17, r0, 0");
      else
        println("  SARI32 r17, r16, 31");
    }
    return;
  }

  cast_int(from, to, 16, 16);
}

// 構造体をスタックに写す（r16 が構造体の番地）
static void push_struct(Type *ty) {
  int sz = align_to(ty->size, 8);
  println("  ADDI32 sp, sp, -%d", sz);
  depth += sz / 8;
  println("  ADDR32 r17, sp, r0");
  copy_bytes(17, 0, 16, ty->size, ty->align);
}

// レジスタで渡す引数のうち、呼ぶ直前に直接レジスタへ入れられる簡単なもの（定数・変数など）か
static bool is_direct_arg(Node *arg) {
  return !arg->pass_by_stack && is_cheap(arg);
}

static void push_args2(Node *args, bool first_pass) {
  if (!args)
    return;
  push_args2(args->next, first_pass);

  if ((first_pass && !args->pass_by_stack) || (!first_pass && args->pass_by_stack))
    return;
  if (is_direct_arg(args))
    return;

  gen_expr(args);

  if (!args->pass_by_stack) {
    push();
    return;
  }
  switch (args->ty->kind) {
  case TY_STRUCT:
  case TY_UNION:
    push_struct(args->ty);
    break;
  default:
    if (is_pair(args->ty))
      push64_mem();
    else
      push_mem();
  }
}

// 引数を求める。先に「スタックで渡すもの」を後ろから積み（呼ばれた側がそのまま読む）、次に「レジスタで渡すもの」のうち
// 計算の要るものを後ろから一時置き場に置く。簡単なもの（定数・変数）は、呼ぶ直前に直接レジスタへ入れる。
//   - 整数・ポインタは r16〜r21 の 6 個まで。残りはスタック（8 バイトずつ）
//   - 構造体・共用体・8 バイトのスカラー（long long・double）はいつもスタック。float は int と同じ
//   - 構造体を返す関数には、バッファの番地を隠れた最初の引数として渡す
static int push_args(Node *node) {
  int stack = 0, gp = 0;

  if (node->ret_buffer)
    gp++;

  for (Node *arg = node->args; arg; arg = arg->next) {
    Type *ty = arg->ty;

    switch (ty->kind) {
    case TY_STRUCT:
    case TY_UNION:
      arg->pass_by_stack = true;
      stack += align_to(ty->size, 8) / 8;
      break;
    case TY_LONG:
    case TY_DOUBLE:
    case TY_LDOUBLE:
      if (is_pair(ty)) {
        arg->pass_by_stack = true;
        stack++;
        break;
      }
      // fallthrough
    default:
      if (gp++ >= GP_MAX) {
        arg->pass_by_stack = true;
        stack++;
      }
    }
  }

  push_args2(node->args, true);
  push_args2(node->args, false);
  return stack;
}

static void builtin_alloca(void) {
  // r17 = 大きさ。8 の倍数に切り上げる
  println("  ADDI32 r17, r17, 7");
  println("  ANDI32 r17, r17, -8");

  // 一時的に積んであるもの（alloca_bottom 〜 SP）を r17 だけ下へずらす
  int c = count();
  println("  LOAD32_32 r18, r31, %d", current_fn->alloca_bottom->offset);
  println("  SUBR32 r18, r18, sp");          // ずらすバイト数
  println("  ADDR32 r19, sp, r0");           // 元
  println("  SUBR32 sp, sp, r17");
  println("  ADDR32 r20, sp, r0");           // 先
  println("L%s.al.%d:", fid, c);
  println("  CMPEQI32 p1, r18, 0");
  println("  BR32 p1, L%s.ald.%d", fid, c);
  println("  LOAD8U_32 r21, r19, 0");
  println("  STORE8_32 r21, r20, 0");
  println("  ADDI32 r19, r19, 1");
  println("  ADDI32 r20, r20, 1");
  println("  ADDI32 r18, r18, -1");
  println("  JMP32 L%s.al.%d", fid, c);
  println("L%s.ald.%d:", fid, c);

  // alloca_bottom を下げて、空いたところの先頭を返す
  println("  LOAD32_32 r16, r31, %d", current_fn->alloca_bottom->offset);
  println("  SUBR32 r16, r16, r17");
  println("  STORE32_32 r16, r31, %d", current_fn->alloca_bottom->offset);
}

// ---- 32bit の整数の計算・比べる ----

// 計算の命令の名前（R・I・M 形式の前の部分）。32bit の整数の 2 項演算でなければ NULL
static char *arith_name(Node *node) {
  switch (node->kind) {
  case ND_ADD: return "ADD";
  case ND_SUB: return "SUB";
  case ND_MUL: return "MUL";
  case ND_DIV: return node->ty->is_unsigned ? "DIVU" : "DIV";
  case ND_MOD: return node->ty->is_unsigned ? "REMU" : "REM";
  case ND_BITAND: return "AND";
  case ND_BITOR: return "OR";
  case ND_BITXOR: return "XOR";
  case ND_SHL: return "SHL";
  case ND_SHR: return node->lhs->ty->is_unsigned ? "SHR" : "SAR";
  }
  return NULL;
}

static bool is_commutative(NodeKind k) {
  return k == ND_ADD || k == ND_MUL || k == ND_BITAND || k == ND_BITOR || k == ND_BITXOR;
}

// 右の定数を即値の欄に書けるか
static bool imm_ok(Node *node, int32_t v) {
  switch (node->kind) {
  case ND_SUB: return v != INT32_MIN;
  case ND_DIV:
  case ND_MOD: return v != 0;          // 0 で割る例外は、今までどおり実行のときに
  case ND_SHL:
  case ND_SHR: return v >= 0 && v <= 31;
  }
  return true;
}

// dst ← lr op r。r が即値なら imm_ok であること、レジスタ・メモリならそのまま
static void emit_arith(Node *node, int dst, int lr, Opnd *r) {
  char *op = arith_name(node);
  if (r->kind == O_IMM) {
    int32_t v = r->imm;
    NodeKind k = node->kind;
    if ((v == 0 && (k == ND_ADD || k == ND_SUB || k == ND_BITOR || k == ND_BITXOR || k == ND_SHL || k == ND_SHR)) ||
        (v == 1 && (k == ND_MUL || k == ND_DIV)))
      move(dst, lr);
    else if (k == ND_SUB)
      println("  ADDI32 r%d, r%d, %d", dst, lr, -v);
    else
      println("  %sI32 r%d, r%d, %d", op, dst, lr, v);
  } else if (r->kind == O_MEM) {
    char name[16];
    snprintf(name, sizeof(name), "%s32", op);
    emit_m(name, dst, lr, &r->a);
  } else {
    println("  %sR32 r%d, r%d, r%d", op, dst, lr, r->reg);
  }
}

// dst ← lhs op rhs（32bit の整数）
static void gen_arith(Node *node, int dst) {
  Opnd l, r;
  gen_operands(node->lhs, node->rhs, &l, &r);

  // 左はレジスタに。左が即値・メモリで右がレジスタなら、入れ替えられる演算は入れ替える
  if (l.kind != O_REG && r.kind == O_REG && is_commutative(node->kind)) {
    Opnd t = l;
    l = r;
    r = t;
  }
  int lr = opnd_reg(&l, (r.kind == O_REG && r.reg == 17) ? 18 : 17);
  if (r.kind == O_IMM && !imm_ok(node, r.imm)) {
    r.reg = opnd_reg(&r, lr == 17 ? 18 : 17);
    r.kind = O_REG;
  }
  emit_arith(node, dst, lr, &r);
}

// 整数を読む式（メモリの変数・*p・p->x。ビットフィールドでないもの）か
static bool is_load(Node *node) {
  if (!is_integer(node->ty) || is64(node->ty))
    return false;
  switch (node->kind) {
  case ND_VAR:
    return !reg_var(node) && node->var->ty->kind != TY_VLA;
  case ND_MEMBER:
    return !node->member->is_bitfield;
  case ND_DEREF:
    return true;
  }
  return false;
}

// 整数を読んで小さい型に切り詰めるだけの変換か（(char)*p など）。読む命令 1 つでできる（リトルエンディアンなので番地は同じ）
static bool is_narrow_load(Node *node) {
  return node->kind == ND_CAST && is_int32(node->ty) && node->ty->kind != TY_BOOL && node->ty->size < 4 &&
         is_load(node->lhs) && node->lhs->ty->size >= node->ty->size;
}

// dst だけを使って求められる式か（ほかの作業用レジスタを使わず、関数も呼ばない）。gen_cheap で求める。
// 定数・変数・*p や p->x（p はレジスタの変数）・それらの変換・それらと定数や変数の計算
static bool is_cheap(Node *node) {
  int32_t v;
  Opnd r;
  if (node->kind == ND_VAR && (node->ty->kind == TY_ARRAY || node->ty->kind == TY_FUNC))
    return true;                       // 値は番地
  if (!is_word(node->ty))
    return false;
  if (is_imm32(node, &v))
    return true;
  node = strip_cast(node);
  switch (node->kind) {
  case ND_NUM:
    return node->ty->kind == TY_FLOAT;
  case ND_VAR:
    return node->var->ty->kind != TY_VLA;
  case ND_MEMBER:
    if (node->member->is_bitfield)
      return false;
    // fallthrough
  case ND_DEREF:
    return addr_simple(node);
  case ND_ADDR:
    return addr_simple(node->lhs);
  case ND_CAST:
    if (is_narrow_load(node))
      return addr_simple(node->lhs);
    return is_int32(node->ty) && is_int32(node->lhs->ty) && is_cheap(node->lhs);
  case ND_NEG:
  case ND_BITNOT:
    return is_int32(node->ty) && is_cheap(node->lhs);
  }
  if (arith_name(node) && is_int32(node->lhs->ty) && is_int32(node->rhs->ty))
    return is_cheap(node->lhs) && leaf(node->rhs, &r) && (r.kind != O_IMM || imm_ok(node, r.imm));
  return false;
}

// is_cheap な式の値の入ったレジスタ（レジスタの変数ならそれ、0 なら r0、ほかは dst に求める）
static int gen_cheap_val(Node *node, int dst) {
  int32_t v;
  Node *n = strip_cast(node);
  if (reg_var(n))
    return n->var->reg;
  if (is_imm32(node, &v) && v == 0)
    return 0;
  gen_cheap(node, dst);
  return dst;
}

static void gen_cheap(Node *node, int dst) {
  int32_t v;
  Addr a;
  Opnd r;
  if (is_imm32(node, &v)) {
    println("  ADDI32 r%d, r0, %d", dst, v);
    return;
  }
  node = strip_cast(node);
  switch (node->kind) {
  case ND_NUM: {
    union { float f; uint32_t u; } u = { node->fval };
    if (node->fval != node->fval)
      u.u = 0x7FC00000;
    println("  ADDI32 r%d, r0, %d", dst, (int32_t)u.u);
    return;
  }
  case ND_VAR:
    if (reg_var(node)) {
      move(dst, node->var->reg);
      return;
    }
    // fallthrough
  case ND_MEMBER:
  case ND_DEREF:
    gen_addr_op(node, &a);
    load_at(node->ty, dst, &a);
    return;
  case ND_ADDR:
    gen_addr_op(node->lhs, &a);
    emit_mem("ADDI32", dst, &a);
    return;
  case ND_CAST:
    if (is_narrow_load(node)) {
      gen_addr_op(node->lhs, &a);
      load_at(node->ty, dst, &a);
      return;
    }
    cast_int(node->lhs->ty, node->ty, dst, gen_cheap_val(node->lhs, dst));
    return;
  case ND_NEG:
    println("  SUBR32 r%d, r0, r%d", dst, gen_cheap_val(node->lhs, dst));
    return;
  case ND_BITNOT:
    println("  XORI32 r%d, r%d, -1", dst, gen_cheap_val(node->lhs, dst));
    return;
  }
  int lr = gen_cheap_val(node->lhs, dst);
  leaf(node->rhs, &r);
  emit_arith(node, dst, lr, &r);
}

// 比べ方
enum { R_EQ, R_NE, R_LT, R_GE, R_GT, R_LE };

static int negate_rel(int rel) {
  static const int neg[] = {R_NE, R_EQ, R_GE, R_LT, R_LE, R_GT};
  return neg[rel];
}

static int swap_rel(int rel) {                // a rel b ＝ b swap_rel(rel) a
  static const int sw[] = {R_EQ, R_NE, R_GT, R_LE, R_LT, R_GE};
  return sw[rel];
}

// 比べる命令の名前（EQ・NE・LT・GE だけ）
static char *cmp_name(int rel, bool uns) {
  switch (rel) {
  case R_EQ: return "CMPEQ";
  case R_NE: return "CMPNE";
  case R_LT: return uns ? "CMPLTU" : "CMPLT";
  case R_GE: return uns ? "CMPGEU" : "CMPGE";
  }
  unreachable();
}

// 32bit の整数・ポインタの比べる（==・!=・<・<=）か
static bool is_cmp32(Node *node) {
  return (node->kind == ND_EQ || node->kind == ND_NE || node->kind == ND_LT || node->kind == ND_LE) &&
         is_int32(node->lhs->ty) && is_int32(node->rhs->ty);
}

// p1 ←（node の比べた結果 == want）
static void gen_cmp(Node *node, bool want) {
  bool uns = node->lhs->ty->is_unsigned || node->lhs->ty->base;
  int rel = node->kind == ND_EQ ? R_EQ : node->kind == ND_NE ? R_NE : node->kind == ND_LT ? R_LT : R_LE;
  if (!want)
    rel = negate_rel(rel);

  Opnd l, r;
  gen_operands(node->lhs, node->rhs, &l, &r);
  if (l.kind != O_REG && r.kind == O_REG) {
    Opnd t = l;
    l = r;
    r = t;
    rel = swap_rel(rel);
  }
  int lr = opnd_reg(&l, (r.kind == O_REG && r.reg == 17) ? 18 : 17);

  if (r.kind == O_IMM) {
    // a > c は a >= c + 1、a <= c は a < c + 1（c + 1 があふれないとき）
    uint32_t c = (uint32_t)r.imm;
    bool top = uns ? c == UINT32_MAX : (int32_t)c == INT32_MAX;
    if (rel == R_GT && !top) {
      rel = R_GE;
      c++;
    } else if (rel == R_LE && !top) {
      rel = R_LT;
      c++;
    }
    if (rel != R_GT && rel != R_LE) {
      println("  %sI32 p1, r%d, %d", cmp_name(rel, uns), lr, (int32_t)c);
      return;
    }
  } else if (r.kind == O_MEM && rel != R_GT && rel != R_LE) {
    char name[16];
    snprintf(name, sizeof(name), "%s32", cmp_name(rel, uns));
    emit_m(name, 1, lr, &r.a);
    return;
  }

  int rr = opnd_reg(&r, lr == 17 ? 18 : 17);
  if (rel == R_GT)                     // a > b は b < a
    println("  %sR32 p1, r%d, r%d", cmp_name(R_LT, uns), rr, lr);
  else if (rel == R_LE)                // a <= b は b >= a
    println("  %sR32 p1, r%d, r%d", cmp_name(R_GE, uns), rr, lr);
  else
    println("  %sR32 p1, r%d, r%d", cmp_name(rel, uns), lr, rr);
}

static char *new_label(void) {
  return format("L%s.c.%d", fid, count());
}

// 値（型 ty）が 0 なら / 0 でなければ飛ぶ（値は r16 にある）
static void jump_if(Type *ty, char *label, bool nonzero) {
  to_cmp_zero(ty);
  println("  %s p1, r16, 0", nonzero ? "CMPNEI32" : "CMPEQI32");
  println("  BR32 p1, %s", label);
}

// 条件 node の真偽が want なら label へ飛ぶ（値を 0・1 にせず、比べてすぐ分岐する）
static void gen_cond(Node *node, char *label, bool want) {
  switch (node->kind) {
  case ND_NOT:
    gen_cond(node->lhs, label, !want);
    return;
  case ND_LOGAND:
  case ND_LOGOR:
    // && で偽を探す・|| で真を探すなら、どちらかで飛ぶ。逆なら、左で決まったら飛ばずに抜ける
    if (want == (node->kind == ND_LOGOR)) {
      gen_cond(node->lhs, label, want);
      gen_cond(node->rhs, label, want);
    } else {
      char *skip = new_label();
      gen_cond(node->lhs, skip, !want);
      gen_cond(node->rhs, label, want);
      println("%s:", skip);
    }
    return;
  case ND_NUM:
    if (is_integer(node->ty)) {
      if ((node->val != 0) == want)
        println("  JMP32 %s", label);
      return;
    }
    break;
  case ND_CAST:
    // _Bool への変換と、整数・ポインタを切り詰めない変換は、真偽が変わらない
    if (node->ty->kind == TY_BOOL ||
        ((is_integer(node->ty) || node->ty->base) && (is_integer(node->lhs->ty) || node->lhs->ty->base) &&
         node->ty->size >= node->lhs->ty->size)) {
      gen_cond(node->lhs, label, want);
      return;
    }
    break;
  case ND_COMMA:
    gen_void(node->lhs);
    gen_cond(node->rhs, label, want);
    return;
  }

  if (is_cmp32(node)) {
    gen_cmp(node, want);
    println("  BR32 p1, %s", label);
    return;
  }
  if (is_int32(node->ty)) {
    int r = gen_val(node);
    println("  %s p1, r%d, 0", want ? "CMPNEI32" : "CMPEQI32", r);
    println("  BR32 p1, %s", label);
    return;
  }
  gen_expr(node);
  jump_if(node->ty, label, want);
}

// 2 つの値の演算（long long・浮動小数点でないもの）：r16 = 左、r17 = 右
static void gen_binary(Node *node) {
  bool uns = node->lhs->ty->is_unsigned || node->lhs->ty->base;
  char *op = arith_name(node);
  if (op) {
    println("  %sR32 r16, r16, r17", op);
    return;
  }

  switch (node->kind) {
  case ND_EQ:
    println("  CMPEQR32 p1, r16, r17");
    break;
  case ND_NE:
    println("  CMPNER32 p1, r16, r17");
    break;
  case ND_LT:
    println("  %s p1, r16, r17", uns ? "CMPLTUR32" : "CMPLTR32");
    break;
  case ND_LE:                          // a <= b は b >= a
    println("  %s p1, r17, r16", uns ? "CMPGEUR32" : "CMPGER32");
    break;
  default:
    error_tok(node->tok, "invalid expression");
  }
  println("  BTOI32 r16, p1");
}

// 64bit の 2 つの値の演算：r16・r17 = 左、r18・r19 = 右（シフトは r18 が回数）
static void gen_binary64(Node *node) {
  bool uns = node->lhs->ty->is_unsigned;
  int c = count();

  switch (node->kind) {
  case ND_ADD:                         // 下位の桁上がり = 和 < 元の値
    println("  ADDR32 r20, r16, r18");
    println("  CMPLTUR32 p1, r20, r16");
    println("  BTOI32 r21, p1");
    println("  ADDR32 r17, r17, r19");
    println("  ADDR32 r17, r17, r21");
    println("  ADDR32 r16, r20, r0");
    return;
  case ND_SUB:                         // 下位の借り = 左 < 右
    println("  CMPLTUR32 p1, r16, r18");
    println("  BTOI32 r21, p1");
    println("  SUBR32 r16, r16, r18");
    println("  SUBR32 r17, r17, r19");
    println("  SUBR32 r17, r17, r21");
    return;
  case ND_MUL:                         // 上位 = MULHU(a0, b0) + a0 × b1 + a1 × b0
    println("  MULHUR32 r20, r16, r18");
    println("  MULR32 r21, r16, r19");
    println("  ADDR32 r20, r20, r21");
    println("  MULR32 r21, r17, r18");
    println("  ADDR32 r17, r20, r21");
    println("  MULR32 r16, r16, r18");
    return;
  case ND_DIV:
  case ND_MOD: {                       // libc の関数を呼ぶ（引数はどちらもスタック）
    char *fn = node->kind == ND_DIV ? (node->ty->is_unsigned ? "___udivdi3" : "___divdi3")
                                    : (node->ty->is_unsigned ? "___umoddi3" : "___moddi3");
    has_call = true;
    println("  ADDI32 sp, sp, -16");
    println("  STORE32_32 r16, sp, 0");
    println("  STORE32_32 r17, sp, 4");
    println("  STORE32_32 r18, sp, 8");
    println("  STORE32_32 r19, sp, 12");
    println("  CALL32 %s", fn);
    println("  ADDI32 sp, sp, 16");
    return;
  }
  case ND_BITAND:
    println("  ANDR32 r16, r16, r18");
    println("  ANDR32 r17, r17, r19");
    return;
  case ND_BITOR:
    println("  ORR32 r16, r16, r18");
    println("  ORR32 r17, r17, r19");
    return;
  case ND_BITXOR:
    println("  XORR32 r16, r16, r18");
    println("  XORR32 r17, r17, r19");
    return;
  case ND_EQ:
  case ND_NE:
    println("  XORR32 r16, r16, r18");
    println("  XORR32 r17, r17, r19");
    println("  ORR32 r16, r16, r17");
    println("  %s p1, r16, 0", node->kind == ND_EQ ? "CMPEQI32" : "CMPNEI32");
    println("  BTOI32 r16, p1");
    return;
  case ND_LT:                          // 上位が小さい、または上位が同じで下位が小さい（下位は符号なし）
    println("  %s p1, r17, r19", uns ? "CMPLTUR32" : "CMPLTR32");
    println("  BTOI32 r20, p1");
    println("  CMPEQR32 p1, r17, r19");
    println("  BTOI32 r21, p1");
    println("  CMPLTUR32 p1, r16, r18");
    println("  BTOI32 r22, p1");
    println("  ANDR32 r21, r21, r22");
    println("  ORR32 r16, r20, r21");
    return;
  case ND_LE:                          // a <= b は !(b < a)
    println("  %s p1, r19, r17", uns ? "CMPLTUR32" : "CMPLTR32");
    println("  BTOI32 r20, p1");
    println("  CMPEQR32 p1, r17, r19");
    println("  BTOI32 r21, p1");
    println("  CMPLTUR32 p1, r18, r16");
    println("  BTOI32 r22, p1");
    println("  ANDR32 r21, r21, r22");
    println("  ORR32 r16, r20, r21");
    println("  XORI32 r16, r16, 1");
    return;
  case ND_SHL:
    println("  ANDI32 r18, r18, 63");
    println("  CMPLTUI32 p1, r18, 32");
    println("  BR32 p1, L%s.sh.%d", fid, c);
    println("  ADDI32 r18, r18, -32");             // 32 以上：下位を上位へ
    println("  SHLR32 r17, r16, r18");
    println("  ADDI32 r16, r0, 0");
    println("  JMP32 L%s.shd.%d", fid, c);
    println("L%s.sh.%d:", fid, c);
    println("  CMPEQI32 p1, r18, 0");
    println("  BR32 p1, L%s.shd.%d", fid, c);
    println("  ADDI32 r20, r0, 32");
    println("  SUBR32 r20, r20, r18");
    println("  SHRR32 r21, r16, r20");             // 下位からあふれる分
    println("  SHLR32 r17, r17, r18");
    println("  ORR32 r17, r17, r21");
    println("  SHLR32 r16, r16, r18");
    println("L%s.shd.%d:", fid, c);
    return;
  case ND_SHR:
    println("  ANDI32 r18, r18, 63");
    println("  CMPLTUI32 p1, r18, 32");
    println("  BR32 p1, L%s.sh.%d", fid, c);
    println("  ADDI32 r18, r18, -32");             // 32 以上：上位を下位へ
    println("  %s r16, r17, r18", uns ? "SHRR32" : "SARR32");
    if (uns)
      println("  ADDI32 r17, r0, 0");
    else
      println("  SARI32 r17, r17, 31");
    println("  JMP32 L%s.shd.%d", fid, c);
    println("L%s.sh.%d:", fid, c);
    println("  CMPEQI32 p1, r18, 0");
    println("  BR32 p1, L%s.shd.%d", fid, c);
    println("  ADDI32 r20, r0, 32");
    println("  SUBR32 r20, r20, r18");
    println("  SHLR32 r21, r17, r20");             // 上位から下位へ落ちる分
    println("  SHRR32 r16, r16, r18");
    println("  ORR32 r16, r16, r21");
    println("  %s r17, r17, r18", uns ? "SHRR32" : "SARR32");
    println("L%s.shd.%d:", fid, c);
    return;
  }

  error_tok(node->tok, "invalid expression");
}

// 浮動小数点の 2 つの値の演算・比べる（libc/softfloat.c の関数を呼ぶ）
//   float：r16 = 左、r17 = 右。double：スタックに [sp] = 左、[sp + 8] = 右
//   比べる関数は −1（<）・0（=）・1（>）・2（NaN があって比べられない）を返す
static void gen_flonum_binary(Node *node) {
  bool f32 = node->lhs->ty->kind == TY_FLOAT;
  char *fn;
  switch (node->kind) {
  case ND_ADD: fn = f32 ? "___addsf3" : "___adddf3"; break;
  case ND_SUB: fn = f32 ? "___subsf3" : "___subdf3"; break;
  case ND_MUL: fn = f32 ? "___mulsf3" : "___muldf3"; break;
  case ND_DIV: fn = f32 ? "___divsf3" : "___divdf3"; break;
  case ND_EQ:
  case ND_NE:
  case ND_LT:
  case ND_LE:
    fn = f32 ? "___mycpu_fcmp" : "___mycpu_dcmp";
    break;
  default:
    error_tok(node->tok, "invalid operands");
  }

  has_call = true;
  if (f32) {
    gen_expr(node->rhs);
    push();
    gen_expr(node->lhs);
    pop(17);
    println("  CALL32 %s", fn);
  } else {
    gen_expr(node->rhs);
    push64_mem();
    gen_expr(node->lhs);
    push64_mem();
    println("  CALL32 %s", fn);
    println("  ADDI32 sp, sp, 16");
    depth -= 2;
  }

  switch (node->kind) {
  case ND_EQ:
    println("  CMPEQI32 p1, r16, 0");
    println("  BTOI32 r16, p1");
    return;
  case ND_NE:
    println("  CMPNEI32 p1, r16, 0");
    println("  BTOI32 r16, p1");
    return;
  case ND_LT:
    println("  CMPEQI32 p1, r16, -1");
    println("  BTOI32 r16, p1");
    return;
  case ND_LE:                          // −1 か 0：（値 + 1）< 2（符号なし）
    println("  ADDI32 r16, r16, 1");
    println("  CMPLTUI32 p1, r16, 2");
    println("  BTOI32 r16, p1");
    return;
  }
}

// ビットフィールドへ書く：今の値を読み、そこだけ入れ替えて書き戻す。式の値（r16）は書いた値
static void gen_bitfield_assign(Node *node) {
  Member *mem = node->lhs->member;
  if (is64(mem->ty))
    error_tok(node->tok, "long long のビットフィールドはまだ使えない（MyCPU）");
  uint32_t field = mem->bit_width >= 32 ? 0xFFFFFFFFu : ((1u << mem->bit_width) - 1);
  uint32_t mask = field << mem->bit_offset;

  gen_addr(node->lhs);
  push();
  gen_expr(node->rhs);
  println("  ADDR32 r22, r16, r0");          // 書く値（式の値として最後に戻す）
  println("  ANDI32 r19, r16, %d", (int32_t)field);
  println("  SHLI32 r19, r19, %d", mem->bit_offset);
  pop(17);                                     // 番地
  println("  ADDR32 r16, r17, r0");
  load(node, mem->ty);
  println("  ANDI32 r16, r16, %d", (int32_t)~mask);
  println("  ORR32 r16, r16, r19");
  Addr a = {17, 0, NULL};
  store_at(node->ty, 16, &a);
  println("  ADDR32 r16, r22, r0");
}

// 代入（4 バイト以下の整数・ポインタ・float）。式の値を dst に（dst が負なら値は要らない）
static void gen_assign(Node *node, int dst) {
  Node *lhs = node->lhs;
  Addr a;

  // (int){3} = 5 のような (式, 変数) への代入：先に式を求めて、変数へ
  if (lhs->kind == ND_COMMA) {
    gen_void(lhs->lhs);
    Node n = *node;
    n.lhs = lhs->rhs;
    gen_assign(&n, dst);
    return;
  }

  int r = reg_var(lhs);
  if (r) {
    gen_to(node->rhs, r);
    move(dst, r);
    return;
  }

  if (lhs->kind == ND_MEMBER && lhs->member->is_bitfield) {
    gen_bitfield_assign(node);
    move(dst, 16);
    return;
  }

  // char・short へ書くだけ（式の値を使わない）なら、切り詰めなくてよい（書く命令が下位だけを書く）
  Node *rhs = node->rhs;
  if (dst < 0 && is_int32(node->ty) && node->ty->size < 4 && rhs->kind == ND_CAST && is_int32(rhs->lhs->ty) &&
      rhs->lhs->ty->size >= node->ty->size)
    rhs = rhs->lhs;

  // 番地の計算が要らない：値を求めて、そのまま書く
  if (addr_simple(lhs)) {
    int s = gen_val(rhs);
    gen_addr_op(lhs, &a);
    store_at(node->ty, s, &a);
    move(dst, s);
    return;
  }

  // 値が r17 だけで求められる：番地を求めてから値を求める
  if (is_cheap(rhs)) {
    gen_addr_op(lhs, &a);
    int s = gen_cheap_val(rhs, 17);
    store_at(node->ty, s, &a);
    move(dst, s);
    return;
  }

  // 番地を一時置き場に置いてから値を求める
  gen_addr_op(lhs, &a);
  if (a.base == 16) {
    push();
    gen_to(rhs, 16);
    a.base = pop_reg(17);
  } else {
    gen_to(rhs, 16);
  }
  store_at(node->ty, 16, &a);
  move(dst, 16);
}

// 式の値を dst に（dst が r16 でないのは、4 バイト以下の整数・ポインタ・float の式のときだけ）
static void gen_to(Node *node, int dst) {
  Addr a;
  int r;

  if (is_word(node->ty)) {
    switch (node->kind) {
    case ND_NUM:
      // ビット列をそのまま入れる。NaN はいつも 0x7FC00000（libc/softfloat.c と同じ）
      if (node->ty->kind == TY_FLOAT) {
        union { float f; uint32_t u; } u = { node->fval };
        if (node->fval != node->fval)
          u.u = 0x7FC00000;
        println("  ADDI32 r%d, r0, %d", dst, (int32_t)u.u);
        return;
      }
      println("  ADDI32 r%d, r0, %d", dst, (int32_t)node->val);
      return;
    case ND_VAR:
      if (reg_var(node)) {
        move(dst, node->var->reg);
        return;
      }
      if (node->var->ty->kind == TY_VLA)
        break;
      gen_addr_op(node, &a);
      load_at(node->ty, dst, &a);
      return;
    case ND_MEMBER:
      if (node->member->is_bitfield)
        break;
      // fallthrough
    case ND_DEREF:
      gen_addr_op(node, &a);
      load_at(node->ty, dst, &a);
      return;
    case ND_ADDR:
      if (node->lhs->kind == ND_DEREF) {          // &*p は p
        gen_to(node->lhs->lhs, dst);
        return;
      }
      gen_addr_op(node->lhs, &a);
      emit_mem("ADDI32", dst, &a);
      return;
    case ND_ASSIGN:
      gen_assign(node, dst);
      return;
    case ND_CAST: {
      int32_t v;
      if (is_imm32(node, &v)) {
        println("  ADDI32 r%d, r0, %d", dst, v);
        return;
      }
      if (strip_cast(node) != node) {             // 何もしない変換
        gen_to(strip_cast(node), dst);
        return;
      }
      if (node->ty->kind == TY_BOOL && is_bool_valued(node->lhs)) {
        gen_to(node->lhs, dst);
        return;
      }
      if (is_narrow_load(node)) {
        gen_addr_op(node->lhs, &a);
        load_at(node->ty, dst, &a);
        return;
      }
      if (is_int32(node->lhs->ty) && is_int32(node->ty)) {
        r = gen_val(node->lhs);
        cast_int(node->lhs->ty, node->ty, dst, r);
        return;
      }
      break;
    }
    case ND_NEG:
      if (is_int32(node->ty)) {
        r = gen_val(node->lhs);
        println("  SUBR32 r%d, r0, r%d", dst, r);
        return;
      }
      if (node->ty->kind == TY_FLOAT) {          // 符号のビットを反転する
        r = gen_val(node->lhs);
        println("  XORI32 r%d, r%d, %d", dst, r, INT32_MIN);
        return;
      }
      break;
    case ND_BITNOT:
      r = gen_val(node->lhs);
      println("  XORI32 r%d, r%d, -1", dst, r);
      return;
    case ND_NOT:
      if (is_int32(node->lhs->ty)) {
        r = gen_val(node->lhs);
        println("  CMPEQI32 p1, r%d, 0", r);
        println("  BTOI32 r%d, p1", dst);
        return;
      }
      break;
    case ND_EQ:
    case ND_NE:
    case ND_LT:
    case ND_LE:
      if (is_cmp32(node)) {
        gen_cmp(node, true);
        println("  BTOI32 r%d, p1", dst);
        return;
      }
      break;
    case ND_LOGAND:
    case ND_LOGOR: {
      char *f = new_label(), *end = new_label();
      gen_cond(node, f, false);
      println("  ADDI32 r%d, r0, 1", dst);
      println("  JMP32 %s", end);
      println("%s:", f);
      println("  ADDI32 r%d, r0, 0", dst);
      println("%s:", end);
      return;
    }
    case ND_COND: {
      char *els = new_label(), *end = new_label();
      gen_cond(node->cond, els, false);
      gen_to(node->then, dst);
      println("  JMP32 %s", end);
      println("%s:", els);
      gen_to(node->els, dst);
      println("%s:", end);
      return;
    }
    case ND_COMMA:
      gen_void(node->lhs);
      gen_to(node->rhs, dst);
      return;
    default:
      if (arith_name(node) && is_int32(node->lhs->ty) && is_int32(node->rhs->ty)) {
        gen_arith(node, dst);
        return;
      }
    }
  }

  gen_expr2(node);
  move(dst, 16);
}

// 値の入ったレジスタを返す。レジスタの変数ならそのレジスタ、0 なら r0（どちらもコードなし）、ほかは r16 に求める
static int gen_val(Node *node) {
  int32_t v;
  Node *n = strip_cast(node);
  if (reg_var(n))
    return n->var->reg;
  if (is_imm32(node, &v) && v == 0)
    return 0;
  gen_to(node, 16);
  return 16;
}

// 値を使わない式（文としての式、for の 3 つ目など）。副作用だけを起こす
static void gen_void(Node *node) {
  switch (node->kind) {
  case ND_NULL_EXPR:
  case ND_NUM:
  case ND_VAR:
    return;
  case ND_CAST:
    gen_void(node->lhs);
    return;
  case ND_COMMA:
    // int x = 式; は「x を 0 で埋めて、x = 式」になっている。スカラーなら 0 で埋めなくてよい
    if (node->lhs->kind == ND_MEMZERO && is_word(node->lhs->var->ty) && node->rhs->kind == ND_ASSIGN &&
        node->rhs->lhs->kind == ND_VAR && node->rhs->lhs->var == node->lhs->var) {
      gen_void(node->rhs);
      return;
    }
    gen_void(node->lhs);
    gen_void(node->rhs);
    return;
  case ND_ADD:
  case ND_SUB:
  case ND_MUL:
  case ND_BITAND:
  case ND_BITOR:
  case ND_BITXOR:
  case ND_SHL:
  case ND_SHR:
  case ND_EQ:
  case ND_NE:
  case ND_LT:
  case ND_LE:
    gen_void(node->lhs);
    gen_void(node->rhs);
    return;
  case ND_NEG:
  case ND_BITNOT:
  case ND_NOT:
    gen_void(node->lhs);
    return;
  case ND_ASSIGN:
    if (is_word(node->ty)) {
      gen_assign(node, -1);
      return;
    }
    break;
  case ND_LOGAND:
  case ND_LOGOR: {
    char *end = new_label();
    gen_cond(node->lhs, end, node->kind == ND_LOGOR);
    gen_void(node->rhs);
    println("%s:", end);
    return;
  }
  case ND_COND: {
    char *els = new_label(), *end = new_label();
    gen_cond(node->cond, els, false);
    gen_void(node->then);
    println("  JMP32 %s", end);
    println("%s:", els);
    gen_void(node->els);
    println("%s:", end);
    return;
  }
  }
  gen_expr(node);
}

// Generate code for a given node.（値を r16 に。8 バイトなら r16・r17、構造体などは番地）
static void gen_expr(Node *node) {
  if (is_word(node->ty))
    gen_to(node, 16);
  else
    gen_expr2(node);
}

// gen_to が扱わない式（8 バイトの値・構造体・関数呼び出しなど）。値を r16 に
static void gen_expr2(Node *node) {
  switch (node->kind) {
  case ND_NULL_EXPR:
    return;
  case ND_NUM:
    // ビット列をそのまま入れる。NaN はいつも 0x7FF8000000000000（libc/softfloat.c と同じ。
    // PC の上で 0.0 / 0.0 を計算すると符号つきの NaN になることがあるので、そろえる）
    if (is_flonum(node->ty)) {
      union { double d; uint64_t u; } u = { node->fval };
      if (node->fval != node->fval)
        u.u = 0x7FF8000000000000ULL;
      println("  ADDI32 r16, r0, %d", (int32_t)u.u);
      println("  ADDI32 r17, r0, %d", (int32_t)(u.u >> 32));
      return;
    }
    println("  ADDI32 r16, r0, %d", (int32_t)node->val);
    if (is64(node->ty))
      println("  ADDI32 r17, r0, %d", (int32_t)(node->val >> 32));
    return;
  case ND_NEG:
    gen_expr(node->lhs);
    if (is_flonum(node->ty)) {
      println("  XORI32 r17, r17, %d", INT32_MIN);
      return;
    }
    if (is64(node->ty)) {             // −(上位:下位)：下位が 0 でなければ上位から 1 借りる
      println("  SUBR32 r16, r0, r16");
      println("  CMPNEI32 p1, r16, 0");
      println("  BTOI32 r18, p1");
      println("  SUBR32 r17, r0, r17");
      println("  SUBR32 r17, r17, r18");
      return;
    }
    println("  SUBR32 r16, r0, r16");
    return;
  case ND_VAR:
  case ND_MEMBER: {
    gen_addr(node);
    load(node, node->ty);

    if (node->kind == ND_MEMBER && node->member->is_bitfield) {
      Member *mem = node->member;
      if (is64(mem->ty))
        error_tok(node->tok, "long long のビットフィールドはまだ使えない（MyCPU）");
      println("  SHLI32 r16, r16, %d", 32 - mem->bit_width - mem->bit_offset);
      if (mem->ty->is_unsigned)
        println("  SHRI32 r16, r16, %d", 32 - mem->bit_width);
      else
        println("  SARI32 r16, r16, %d", 32 - mem->bit_width);
    }
    return;
  }
  case ND_DEREF:
    gen_expr(node->lhs);
    load(node, node->ty);
    return;
  case ND_ADDR:
    gen_addr(node->lhs);
    return;
  case ND_ASSIGN:
    if (node->lhs->kind == ND_MEMBER && node->lhs->member->is_bitfield) {
      gen_bitfield_assign(node);
      return;
    }

    // 構造体：書く先の番地の計算が要らなければ、元の番地（r16）から直接写す
    if ((node->ty->kind == TY_STRUCT || node->ty->kind == TY_UNION) && addr_simple(node->lhs)) {
      Addr a;
      gen_expr(node->rhs);
      gen_addr_op(node->lhs, &a);
      if (a.sym) {
        emit_mem("ADDI32", 17, &a);
        a.base = 17;
        a.off = 0;
      }
      copy_bytes(a.base, a.off, 16, node->ty->size, node->ty->align);
      return;
    }

    gen_addr(node->lhs);
    push();
    gen_expr(node->rhs);

    if (node->ty->kind == TY_STRUCT || node->ty->kind == TY_UNION) {
      int b = pop_reg(17);
      copy_bytes(b, 0, 16, node->ty->size, node->ty->align);
      return;
    }
    if (is_pair(node->ty)) {
      Addr a = {pop_reg(22), 0, NULL};
      store_at(node->ty, 16, &a);
      return;
    }
    {
      Addr a = {pop_reg(17), 0, NULL};
      store_at(node->ty, 16, &a);
    }
    return;
  case ND_STMT_EXPR:
    // 最後の式文の値が、全体の値
    for (Node *n = node->body; n; n = n->next) {
      if (!n->next && n->kind == ND_EXPR_STMT)
        gen_expr(n->lhs);
      else
        gen_stmt(n);
    }
    return;
  case ND_COMMA:
    gen_void(node->lhs);
    gen_expr(node->rhs);
    return;
  case ND_CAST:
    gen_expr(node->lhs);
    cast(node, node->lhs->ty, node->ty);
    return;
  case ND_MEMZERO: {
    if (node->var->reg) {
      println("  ADDR32 r%d, r0, r0", node->var->reg);
      return;
    }
    int size = node->var->ty->size;
    if (size <= 64 && size % 4 == 0 && node->var->align >= 4 && node->var->offset % 4 == 0) {
      for (int i = 0; i < size; i += 4)
        println("  STORE32_32 r0, r31, %d", node->var->offset + i);
      return;
    }
    int c = count();
    println("  ADDI32 r17, r31, %d", node->var->offset);
    println("  ADDI32 r18, r17, %d", size);
    println("L%s.z.%d:", fid, c);
    println("  CMPGEUR32 p1, r17, r18");
    println("  BR32 p1, L%s.zd.%d", fid, c);
    println("  STORE8_32 r0, r17, 0");
    println("  ADDI32 r17, r17, 1");
    println("  JMP32 L%s.z.%d", fid, c);
    println("L%s.zd.%d:", fid, c);
    return;
  }
  case ND_COND: {
    char *els = new_label(), *end = new_label();
    gen_cond(node->cond, els, false);
    gen_expr(node->then);
    println("  JMP32 %s", end);
    println("%s:", els);
    gen_expr(node->els);
    println("%s:", end);
    return;
  }
  case ND_NOT:
    gen_expr(node->lhs);
    to_cmp_zero(node->lhs->ty);
    println("  CMPEQI32 p1, r16, 0");
    println("  BTOI32 r16, p1");
    return;
  case ND_BITNOT:
    gen_expr(node->lhs);
    println("  XORI32 r16, r16, -1");
    if (is64(node->ty))
      println("  XORI32 r17, r17, -1");
    return;
  case ND_LOGAND:
  case ND_LOGOR: {
    char *f = new_label(), *end = new_label();
    gen_cond(node, f, false);
    println("  ADDI32 r16, r0, 1");
    println("  JMP32 %s", end);
    println("%s:", f);
    println("  ADDI32 r16, r0, 0");
    println("%s:", end);
    return;
  }
  case ND_FUNCALL: {
    if (node->lhs->kind == ND_VAR && !strcmp(node->lhs->var->name, "alloca")) {
      gen_expr(node->args);
      println("  ADDR32 r17, r16, r0");
      builtin_alloca();
      return;
    }

    has_call = true;
    int stack_args = push_args(node);

    // 名前の決まった関数は直接 CALL32。関数ポインタは CALLR32（r16 に求めたら r22 へ）
    bool direct = node->lhs->kind == ND_VAR && !node->lhs->var->is_local && node->lhs->var->ty->kind == TY_FUNC;
    int fr = 0;
    if (!direct) {
      fr = gen_val(node->lhs);
      if (fr < REG_LO) {
        move(22, fr);
        fr = 22;
      }
    }

    // 一時置き場の引数を r16〜 へ。そのあと簡単な引数を直接
    int gp0 = node->ret_buffer ? 1 : 0, gp = gp0;
    for (Node *arg = node->args; arg; arg = arg->next) {
      if (arg->pass_by_stack)
        continue;
      if (!is_direct_arg(arg))
        pop(16 + gp);
      gp++;
    }
    gp = gp0;
    for (Node *arg = node->args; arg; arg = arg->next) {
      if (arg->pass_by_stack)
        continue;
      if (is_direct_arg(arg))
        gen_cheap(arg, 16 + gp);
      gp++;
    }
    if (node->ret_buffer)
      println("  ADDI32 r16, r31, %d", node->ret_buffer->offset);

    if (direct)
      println("  CALL32 %s", sym_name(node->lhs->var->name));
    else
      println("  CALLR32 r%d", fr);

    if (stack_args) {
      println("  ADDI32 sp, sp, %d", stack_args * 8);
      depth -= stack_args;
    }

    switch (node->ty->kind) {
    case TY_BOOL:
      println("  ANDI32 r16, r16, 1");
      return;
    case TY_CHAR:
      if (node->ty->is_unsigned) {
        println("  ANDI32 r16, r16, 0xFF");
      } else {
        println("  SHLI32 r16, r16, 24");
        println("  SARI32 r16, r16, 24");
      }
      return;
    case TY_SHORT:
      if (node->ty->is_unsigned) {
        println("  ANDI32 r16, r16, 0xFFFF");
      } else {
        println("  SHLI32 r16, r16, 16");
        println("  SARI32 r16, r16, 16");
      }
      return;
    }

    // 構造体を返す関数：値は渡したバッファに入っている
    if (node->ret_buffer)
      println("  ADDI32 r16, r31, %d", node->ret_buffer->offset);
    return;
  }
  case ND_LABEL_VAL:
    println("  ADDI32 r16, r0, %s", sym_name(node->unique_label));
    return;
  case ND_CAS: {
    // 割り込みのない 1 つの CPU なので、ふつうに読んで比べて書く
    int sz = node->cas_addr->ty->base->size;
    if (sz > 4)
      error_tok(node->tok, "8 バイトの __builtin_compare_and_swap はまだ使えない（MyCPU）");
    char *ld = sz == 1 ? "LOAD8U_32" : sz == 2 ? "LOAD16U_32" : "LOAD32_32";
    char *st = sz == 1 ? "STORE8_32" : sz == 2 ? "STORE16_32" : "STORE32_32";
    int c = count();
    gen_expr(node->cas_addr);
    push();
    gen_expr(node->cas_new);
    push();
    gen_expr(node->cas_old);
    println("  ADDR32 r20, r16, r0");          // old の番地
    pop(17);                                     // new
    pop(18);                                     // addr
    println("  %s r19, r20, 0", ld);            // 期待する値
    println("  %s r21, r18, 0", ld);            // 今の値
    println("  CMPEQR32 p1, r19, r21");
    println("  BR32 p1, L%s.cas.%d", fid, c);
    println("  %s r21, r20, 0", st);
    println("  ADDI32 r16, r0, 0");
    println("  JMP32 L%s.casd.%d", fid, c);
    println("L%s.cas.%d:", fid, c);
    println("  %s r17, r18, 0", st);
    println("  ADDI32 r16, r0, 1");
    println("L%s.casd.%d:", fid, c);
    return;
  }
  case ND_EXCH: {
    int sz = node->lhs->ty->base->size;
    if (sz > 4)
      error_tok(node->tok, "8 バイトの __builtin_atomic_exchange はまだ使えない（MyCPU）");
    gen_expr(node->lhs);
    push();
    gen_expr(node->rhs);
    pop(17);
    if (sz == 4) {
      println("  SWAP32 r16, r17, r16, 0");
    } else {
      println("  ADDR32 r18, r16, r0");
      println("  %s r16, r17, 0", sz == 1 ? "LOAD8U_32" : "LOAD16U_32");
      println("  %s r18, r17, 0", sz == 1 ? "STORE8_32" : "STORE16_32");
    }
    return;
  }
  }

  if (is_flonum(node->lhs->ty)) {
    gen_flonum_binary(node);
    return;
  }

  // 右を積んでから左を求める。右は 32bit なら r17、long long なら r18・r19
  // （シフトの右は左と型が違うことがある。そのときは下位だけ使う）
  gen_expr(node->rhs);
  push_val(node->rhs->ty);
  gen_expr(node->lhs);
  if (is64(node->lhs->ty)) {
    if (is64(node->rhs->ty))
      pop64(18, 19);
    else
      pop(18);
    gen_binary64(node);
    return;
  }
  if (is64(node->rhs->ty))
    pop64(17, 18);
  else
    pop(17);
  gen_binary(node);
}

static void gen_stmt(Node *node) {
  switch (node->kind) {
  case ND_IF: {
    char *els = new_label();
    gen_cond(node->cond, els, false);
    gen_stmt(node->then);
    if (node->els) {
      char *end = new_label();
      println("  JMP32 %s", end);
      println("%s:", els);
      gen_stmt(node->els);
      println("%s:", end);
    } else {
      println("%s:", els);
    }
    return;
  }
  case ND_FOR: {
    // 条件は最後に置く（1 回まわるごとの JMP を 1 つ減らす）：最初は条件へ飛ぶ
    if (node->init)
      gen_stmt(node->init);
    Node *cond = node->cond;
    if (cond && cond->kind == ND_NUM && is_integer(cond->ty) && cond->val)
      cond = NULL;                     // for (;;)・while (1)
    char *top = new_label(), *test = new_label();
    if (cond)
      println("  JMP32 %s", test);
    println("%s:", top);
    gen_stmt(node->then);
    println("%s:", sym_name(node->cont_label));
    if (node->inc)
      gen_void(node->inc);
    if (cond) {
      println("%s:", test);
      gen_cond(cond, top, true);
    } else {
      println("  JMP32 %s", top);
    }
    println("%s:", sym_name(node->brk_label));
    return;
  }
  case ND_DO: {
    char *top = new_label();
    println("%s:", top);
    gen_stmt(node->then);
    println("%s:", sym_name(node->cont_label));
    gen_cond(node->cond, top, true);
    println("%s:", sym_name(node->brk_label));
    return;
  }
  case ND_SWITCH: {
    int r = 16;
    if (is_int32(node->cond->ty))
      r = gen_val(node->cond);
    else
      gen_expr(node->cond);

    for (Node *n = node->case_next; n; n = n->case_next) {
      if (is64(node->cond->ty)) {      // long long：上位と下位の両方が同じか
        if (n->begin != n->end)
          error_tok(n->tok, "long long の case の範囲はまだ使えない（MyCPU）");
        println("  XORI32 r20, r16, %d", (int32_t)n->begin);
        println("  XORI32 r21, r17, %d", (int32_t)(n->begin >> 32));
        println("  ORR32 r20, r20, r21");
        println("  CMPEQI32 p1, r20, 0");
        println("  BR32 p1, %s", sym_name(n->label));
        continue;
      }

      if (n->begin == n->end) {
        println("  CMPEQI32 p1, r%d, %d", r, (int32_t)n->begin);
        println("  BR32 p1, %s", sym_name(n->label));
        continue;
      }

      // [GNU] Case ranges：begin ≦ 値 ≦ end は（値 − begin）≦（end − begin）（符号なし）
      println("  ADDI32 r17, r%d, %d", r, (int32_t)-n->begin);
      println("  ADDI32 r18, r0, %d", (int32_t)(n->end - n->begin));
      println("  CMPGEUR32 p1, r18, r17");
      println("  BR32 p1, %s", sym_name(n->label));
    }

    if (node->default_case)
      println("  JMP32 %s", sym_name(node->default_case->label));

    println("  JMP32 %s", sym_name(node->brk_label));
    gen_stmt(node->then);
    println("%s:", sym_name(node->brk_label));
    return;
  }
  case ND_CASE:
    println("%s:", sym_name(node->label));
    gen_stmt(node->lhs);
    return;
  case ND_BLOCK:
    for (Node *n = node->body; n; n = n->next)
      gen_stmt(n);
    return;
  case ND_GOTO:
    println("  JMP32 %s", sym_name(node->unique_label));
    return;
  case ND_GOTO_EXPR:
    println("  JMPR32 r%d", gen_val(node->lhs));
    return;
  case ND_LABEL:
    println("%s:", sym_name(node->unique_label));
    gen_stmt(node->lhs);
    return;
  case ND_RETURN:
    if (node->lhs) {
      gen_expr(node->lhs);
      Type *ty = node->lhs->ty;

      // 構造体：隠れた最初の引数（呼ぶ側のバッファ）へ写す
      if (ty->kind == TY_STRUCT || ty->kind == TY_UNION) {
        Obj *p = current_fn->params;
        if (p->reg)
          move(17, p->reg);
        else
          println("  LOAD32_32 r17, r31, %d", p->offset);
        copy_bytes(17, 0, 16, ty->size, ty->align);
      }
    }

    println("  JMP32 L%s.ret.%s", fid, current_fn->name);
    return;
  case ND_EXPR_STMT:
    gen_void(node->lhs);
    return;
  case ND_ASM:
    println("  %s", node->asm_str);
    return;
  }

  error_tok(node->tok, "invalid statement");
}

// ---- レジスタの割り当て ----

static bool ra_setjmp;                 // setjmp を呼ぶ
static bool ra_call;                   // 関数を呼ぶ（浮動小数点・long long の割り算は libc を呼ぶ）
static bool ra_hiscratch;              // r19〜r22 を作業に使う（構造体を写す・long long・ビットフィールド・CAS）

// 番地を取られる変数に印を付ける（&x、&x.member）
static void ra_mark_addr(Node *node) {
  while (node) {
    if (node->kind == ND_VAR) {
      node->var->ra_noreg = true;
      return;
    }
    if (node->kind == ND_MEMBER)
      node = node->lhs;
    else if (node->kind == ND_COMMA)
      node = node->rhs;
    else
      return;
  }
}

// 関数の中を見て、ローカル変数を使う回数を数える（ループの中は 8 倍ずつ）
static void ra_scan(Node *node, int w) {
  if (!node)
    return;
  if (node->ty && is_flonum(node->ty))
    ra_call = true;
  if (node->ty && is64(node->ty)) {
    ra_hiscratch = true;
    if (node->kind == ND_DIV || node->kind == ND_MOD)
      ra_call = true;
  }
  switch (node->kind) {
  case ND_ASSIGN:
    if (node->ty->kind == TY_STRUCT || node->ty->kind == TY_UNION ||
        (node->lhs->kind == ND_MEMBER && node->lhs->member->is_bitfield))
      ra_hiscratch = true;
    break;
  case ND_RETURN:
    if (node->lhs && (node->lhs->ty->kind == TY_STRUCT || node->lhs->ty->kind == TY_UNION))
      ra_hiscratch = true;
    break;
  case ND_CAS:
  case ND_EXCH:
    ra_hiscratch = true;
    break;
  case ND_VAR:
    if (node->var->is_local && node->var->ra_weight < (1 << 28))
      node->var->ra_weight += w;
    return;
  case ND_MEMZERO:
    if (node->var->is_local)
      node->var->ra_weight += w;
    return;
  case ND_ADDR:
    ra_mark_addr(node->lhs);
    break;
  case ND_FUNCALL:
    ra_call = true;
    if (node->lhs->kind == ND_VAR) {
      char *name = node->lhs->var->name;
      if (!strcmp(name, "alloca"))
        current_fn->ra_alloca = true;
      if (strstr(name, "setjmp"))
        ra_setjmp = true;
    }
    break;
  case ND_ASM:
    current_fn->ra_asm = true;
    return;
  case ND_FOR:
  case ND_DO: {
    ra_scan(node->init, w);
    int w2 = w < (1 << 20) ? w * 8 : w;
    ra_scan(node->cond, w2);
    ra_scan(node->then, w2);
    ra_scan(node->inc, w2);
    return;
  }
  }
  ra_scan(node->lhs, w);
  ra_scan(node->rhs, w);
  ra_scan(node->cond, w);
  ra_scan(node->then, w);
  ra_scan(node->els, w);
  ra_scan(node->init, w);
  ra_scan(node->inc, w);
  for (Node *n = node->body; n; n = n->next)
    ra_scan(n, w);
  for (Node *n = node->args; n; n = n->next)
    ra_scan(n, w);
  ra_scan(node->cas_addr, w);
  ra_scan(node->cas_old, w);
  ra_scan(node->cas_new, w);
}

// レジスタに置ける変数か
static bool ra_ok(Obj *fn, Obj *var) {
  return is_word(var->ty) && !var->ra_noreg && var != fn->va_area && var != fn->alloca_bottom;
}

// よく使う変数（3 回以上）から順にレジスタを割り当てる。
//   関数を呼ばない関数：まず r23〜r19（呼んだ側が保存するので、保存しなくてよい。r19〜r22 は作業に使わないときだけ）。
//     r19〜r21 で来る引数（4〜6 個目）をレジスタに置くなら、来たレジスタのまま
//   ほか（足りない分も）：r24 から最大 VAR_MAX 個（入口で保存する）
static void assign_regs(Obj *fn) {
  for (Obj *var = fn->locals; var; var = var->next) {
    var->reg = 0;
    var->ra_weight = 0;
    var->ra_noreg = false;
  }
  current_fn = fn;
  fn->ra_alloca = fn->ra_asm = false;
  ra_setjmp = ra_call = ra_hiscratch = false;
  ra_scan(fn->body, 1);

  fn->ra_nvars = 0;
  if (fn->ra_asm || ra_setjmp)
    return;

  // 呼ばない関数で使えるレジスタ（used = 使った・取っておいた）
  bool leaf_ok[32] = {}, used[32] = {};
  if (!ra_call && !fn->va_area) {
    leaf_ok[23] = true;
    if (!ra_hiscratch)
      leaf_ok[19] = leaf_ok[20] = leaf_ok[21] = leaf_ok[22] = true;
  }

  // レジスタで来る引数とそのレジスタ。r19〜r21 で来て、レジスタに置けそうなものには、そのレジスタを取っておく
  Obj *in_var[GP_MAX];
  int nin = 0;
  for (Obj *var = fn->params; var && nin < GP_MAX; var = var->next)
    if (var->ty->kind != TY_STRUCT && var->ty->kind != TY_UNION && !is_pair(var->ty))
      in_var[nin++] = var;
  for (int i = 0; i < nin; i++)
    if (leaf_ok[16 + i] && ra_ok(fn, in_var[i]) && in_var[i]->ra_weight >= 3)
      used[16 + i] = true;

  for (;;) {
    Obj *best = NULL;
    for (Obj *var = fn->locals; var; var = var->next)
      if (!var->reg && ra_ok(fn, var) && var->ra_weight >= 3 && (!best || var->ra_weight > best->ra_weight))
        best = var;
    if (!best)
      break;

    int r = 0;
    for (int i = 0; i < nin; i++)
      if (in_var[i] == best && leaf_ok[16 + i])
        r = 16 + i;                    // 来たレジスタのまま
    for (int i = 23; !r && i >= 19; i--)
      if (leaf_ok[i] && !used[i])
        r = i;
    if (!r && fn->ra_nvars < VAR_MAX)
      r = REG_LO + fn->ra_nvars++;
    if (!r) {
      best->ra_noreg = true;           // 置けない（ほかの変数を探す）
      continue;
    }
    used[r] = true;
    best->reg = r;
  }
}

// Assign offsets to local variables.
static void assign_lvar_offsets(Obj *prog) {
  for (Obj *fn = prog; fn; fn = fn->next) {
    if (!fn->is_function || !fn->is_definition)
      continue;

    assign_regs(fn);

    // スタックで渡された引数は [r31 + 8] から 8 バイトずつ
    int top = 8;
    int bottom = 0;
    int gp = 0;

    for (Obj *var = fn->params; var; var = var->next) {
      Type *ty = var->ty;
      if (ty->kind != TY_STRUCT && ty->kind != TY_UNION && !is_pair(ty) && gp++ < GP_MAX)
        continue;

      var->offset = top;
      top += align_to(ty->size, 8);
    }

    // レジスタで渡された引数とローカル変数（レジスタに置くもの、使わない alloca の置き場には場所を取らない）
    for (Obj *var = fn->locals; var; var = var->next) {
      if (var->offset || var->reg || (var == fn->alloca_bottom && !fn->ra_alloca))
        continue;

      // 16 バイト以上の配列は 4 の倍数の番地に（memcpy などが 4 バイトずつ動けるように）
      int align = (var->ty->kind == TY_ARRAY && var->ty->size >= 16 && var->align < 4) ? 4 : var->align;
      bottom += var->ty->size;
      bottom = align_to(bottom, align);
      var->offset = -bottom;
    }

    fn->stack_size = align_to(bottom, 8);
  }
}

static void emit_data(Obj *prog) {
  println("; @data");
  for (Obj *var = prog; var; var = var->next) {
    if (var->is_function || !var->is_definition)
      continue;

    // 初期値なしの大域変数（int x; など）は、ほかのファイルの同じ名前とまとめる（tools/cc.js が置く）
    if (opt_fcommon && var->is_tentative && !var->is_static) {
      println("; @common %s %d %d", sym_name(var->name), var->ty->size, var->align);
      continue;
    }

    println("; @obj %s", sym_name(var->name));
    println("  .align %d", var->align < 4 ? 4 : var->align);
    println("%s:", sym_name(var->name));

    // 初期値あり：ポインタ（ほかの大域の番地）は .word、それ以外は 1 バイトずつ
    if (var->init_data) {
      Relocation *rel = var->rel;
      int pos = 0;
      while (pos < var->ty->size) {
        if (rel && rel->offset == pos) {
          int32_t add = (int32_t)rel->addend;
          println("  .word %s %c %d", sym_name(*rel->label), add < 0 ? '-' : '+', add < 0 ? -add : add);
          rel = rel->next;
          pos += 4;
          continue;
        }

        // 次のポインタか終わりまでを、16 バイトずつまとめて書く
        int end = rel ? rel->offset : var->ty->size;
        while (pos < end) {
          int n = end - pos < 16 ? end - pos : 16;
          fprintf(output_file, "  .byte ");
          for (int i = 0; i < n; i++)
            fprintf(output_file, i ? ", %d" : "%d", (unsigned char)var->init_data[pos + i]);
          fprintf(output_file, "\n");
          pos += n;
        }
      }
      continue;
    }

    // 初期値なし（0 で埋める）
    println("  .space %d", var->ty->size);
  }
}

// レジスタで来た引数を、置き場（レジスタかスタック）へ
static void store_param(Obj *var, int r) {
  if (var->reg) {
    cast_int(ty_int, var->ty, var->reg, r);          // char・short は広げ直しておく
    return;
  }
  Addr a = {31, var->offset, NULL};
  store_at(var->ty, r, &a);
}

static bool is_label_line(char *p, int len) {
  return len > 0 && p[0] != ' ' && p[0] != ';' && p[len - 1] == ':';
}

// 「rA, r31, n」「rA, sp, n」（フレームのメモリ。入出力の番地ではない）か
static bool frame_access(char *ops, int n) {
  char *c = memchr(ops, ',', n);
  if (!c)
    return false;
  int rest = n - (c - ops);
  return (rest > 6 && !strncmp(c, ", r31, ", 7)) || (rest > 5 && !strncmp(c, ", sp, ", 6));
}

// 行の長さと次の行
static int line_len(char *p, char **next) {
  char *eol = strchr(p, '\n');
  int len = eol ? eol - p : strlen(p);
  *next = eol ? eol + 1 : p + len;
  return len;
}

// ラベル（行の頭から「:」まで）の後ろの最初の命令の行。なければ NULL
static char *insn_after(char *p) {
  char *next;
  while (*p) {
    int len = line_len(p, &next);
    if (!is_label_line(p, len) && !(len > 0 && p[0] == ';'))
      return p;
    p = next;
  }
  return NULL;
}

// 飛び先のラベルの次がまた JMP32 なら、その先へ（何回か）。ラベル → その後ろの最初の命令（labels）
static void jump_target(HashMap *labels, char **t, int *tlen) {
  for (int i = 0; i < 8; i++) {
    char *q = hashmap_get2(labels, *t, *tlen);
    if (!q || strncmp(q, "  JMP32 ", 8))
      return;
    char *next;
    char *nt = q + 8;
    int ntlen = line_len(q, &next) - 8;
    if (ntlen == *tlen && !strncmp(nt, *t, ntlen))
      return;
    *t = nt;
    *tlen = ntlen;
  }
}

// 関数の本体を写す。そのとき
//   ・飛び先がまた JMP32 なら、その先へ直接飛ぶ
//   ・すぐ後ろのラベルへの JMP32 を消し、JMP32・RET32 の後ろの届かない命令を消す
//   ・フレームへ書いた直後に同じレジスタへ読み戻す命令を消す
static void emit_body(char *buf, bool keep_all) {
  if (keep_all) {
    fputs(buf, output_file);
    return;
  }

  HashMap labels = {};
  char *next;
  for (char *p = buf; *p; p = next) {
    int len = line_len(p, &next);
    if (is_label_line(p, len))
      hashmap_put2(&labels, p, len - 1, insn_after(next));
  }

  bool dead = false;
  char *prev = NULL;
  int prev_len = 0;
  for (char *p = buf; *p; p = next) {
    int len = line_len(p, &next);
    if (is_label_line(p, len))
      dead = false;
    if (dead)
      continue;

    bool jmp = !strncmp(p, "  JMP32 ", 8), br = !strncmp(p, "  BR32 ", 7);
    if (jmp || br) {
      char *target;
      int tlen;
      if (jmp) {
        target = p + 8;
        tlen = len - 8;
      } else {                          // "  BR32 p1, ラベル"
        char *c = memchr(p, ',', len);
        target = c + 2;
        tlen = len - (target - p);
      }
      jump_target(&labels, &target, &tlen);

      // 飛び先が、届かない命令を飛ばした次のラベルの並びにあれば要らない
      if (jmp) {
        bool drop = false, seen = false;
        char *qn;
        for (char *q = next; *q; q = qn) {
          int qlen = line_len(q, &qn);
          if (is_label_line(q, qlen)) {
            seen = true;
            if (qlen == tlen + 1 && !strncmp(q, target, tlen)) {
              drop = true;
              break;
            }
          } else if (seen && !(qlen > 0 && q[0] == ';')) {
            break;
          }
        }
        dead = true;
        if (drop)
          continue;
        fprintf(output_file, "  JMP32 %.*s\n", tlen, target);
      } else {
        char *c = memchr(p, ',', len);
        fprintf(output_file, "%.*s%.*s\n", (int)(c + 2 - p), p, tlen, target);
      }
      prev = NULL;
      continue;
    }

    // STORE32_32 rA, r31, n の直後の LOAD32_32 rA, r31, n（sp も）
    if (prev && !strncmp(p, "  LOAD32_32 ", 12) && !strncmp(prev, "  STORE32_32 ", 13) && len - 12 == prev_len - 13 &&
        !strncmp(p + 12, prev + 13, len - 12) && frame_access(p + 12, len - 12))
      continue;

    if (!strncmp(p, "  RET32", 7) || !strncmp(p, "  JMPR32 ", 9))
      dead = true;
    fwrite(p, 1, next - p, output_file);
    prev = p;
    prev_len = len;
    if (is_label_line(p, len))
      prev = NULL;
  }
  free(labels.buckets);
}

static void emit_text(Obj *prog) {
  println("; @text");
  for (Obj *fn = prog; fn; fn = fn->next) {
    if (!fn->is_function || !fn->is_definition)
      continue;

    // No code is emitted for "static inline" functions
    // if no one is referencing them.
    if (!fn->is_live)
      continue;

    current_fn = fn;
    ntregs = (REG_HI - REG_LO + 1) - fn->ra_nvars;
    tused = tdepth = 0;
    used_regs = 0;
    for (int i = 0; i < fn->ra_nvars; i++)
      used_regs |= 1u << (REG_LO + i);
    has_call = false;

    // 本体をいったん buf に作る（使ったレジスタ・関数を呼んだかが分かってから、入口と出口を書く）
    FILE *out = output_file;
    char *buf;
    size_t buflen;
    output_file = open_memstream(&buf, &buflen);

    // 可変長引数の関数：レジスタの引数を並べて置き、va_list の元（__va_area__）を作る
    //   [off] = 次に読むレジスタの引数（バイト）、[off + 4] = スタックの引数、[off + 8] = レジスタの引数の置き場
    //   [off + 16] 〜 = r16〜r21（8 バイトずつ）
    if (fn->va_area) {
      int gp = 0;                      // レジスタで来た名前付きの引数の数
      for (Obj *var = fn->params; var; var = var->next)
        if (var->ty->kind != TY_STRUCT && var->ty->kind != TY_UNION && !is_pair(var->ty) && gp < GP_MAX)
          gp++;

      int off = fn->va_area->offset;
      println("  ADDI32 r22, r0, %d", gp * 8);
      println("  STORE32_32 r22, r31, %d", off);
      println("  ADDI32 r22, r31, 8");
      println("  STORE32_32 r22, r31, %d", off + 4);
      println("  ADDI32 r22, r31, %d", off + 16);
      println("  STORE32_32 r22, r31, %d", off + 8);
      for (int i = 0; i < GP_MAX; i++)
        println("  STORE32_32 r%d, r31, %d", 16 + i, off + 16 + i * 8);
    }

    // 引数を置き場へ：レジスタで来たもの（先にメモリへ書くものを、それからレジスタへ移すものを。
    // 移す先が、まだ移していない引数のレジスタにならないように）と、スタックで来てレジスタに置くもの
    bool stack_params = false;
    for (int pass = 0; pass < 2; pass++) {
      int gp = 0;
      for (Obj *var = fn->params; var; var = var->next) {
        if (var->offset > 0)
          continue;
        if (!var->reg == !pass)
          store_param(var, 16 + gp);
        gp++;
      }
    }
    for (Obj *var = fn->params; var; var = var->next) {
      if (var->offset > 0) {
        stack_params = true;
        if (var->reg) {
          Addr a = {31, var->offset, NULL};
          load_at(var->ty, var->reg, &a);
        }
      }
    }

    // Emit code
    gen_stmt(fn->body);
    assert(depth == 0 && tdepth == 0);

    // [https://www.sigbus.info/n1570#5.1.2.2.3p1] The C spec defines
    // a special rule for the main function. Reaching the end of the
    // main function is equivalent to returning 0, even though the
    // behavior is undefined for the other functions.
    if (strcmp(fn->name, "main") == 0)
      println("  ADDI32 r16, r0, 0");
    println("L%s.ret.%s:", fid, fn->name);

    fclose(output_file);
    output_file = out;

    int saved[REG_HI - REG_LO + 1], nsaved = 0;
    for (int r = REG_LO; r <= REG_HI; r++)
      if (used_regs & (1u << r))
        saved[nsaved++] = r;

    println("; @fn %s", sym_name(fn->name));
    println("%s:", sym_name(fn->name));

    // メモリにローカル変数・スタックの引数などがなければ、r31（フレームポインタ）を使わない：
    //   [sp] = lr（関数を呼ぶときだけ）、その上に保存したレジスタ
    if (!fn->stack_size && !fn->va_area && !fn->ra_alloca && !stack_params) {
      int base = has_call ? 4 : 0;
      int frame = align_to(base + 4 * nsaved, 8);
      if (frame)
        println("  ADDI32 sp, sp, %d", -frame);
      if (has_call)
        println("  STORE32_32 lr, sp, 0");
      for (int i = 0; i < nsaved; i++)
        println("  STORE32_32 r%d, sp, %d", saved[i], base + 4 * i);
      emit_body(buf, fn->ra_asm);
      free(buf);
      for (int i = 0; i < nsaved; i++)
        println("  LOAD32_32 r%d, sp, %d", saved[i], base + 4 * i);
      if (has_call)
        println("  LOAD32_32 lr, sp, 0");
      if (frame)
        println("  ADDI32 sp, sp, %d", frame);
      println("  RET32");
      continue;
    }

    // Prologue：lr（関数を呼ぶときだけ）と r31 を積み、r31 をフレームの基準にして、ローカル変数の分だけ SP を下げる。
    // 保存するレジスタは、ローカル変数の下に
    int frame = align_to(fn->stack_size + 4 * nsaved, 8);
    println("  ADDI32 sp, sp, -8");
    if (has_call)
      println("  STORE32_32 lr, sp, 0");
    println("  STORE32_32 r31, sp, 4");
    println("  ADDR32 r31, sp, r0");
    if (frame)
      println("  ADDI32 sp, sp, %d", -frame);
    for (int i = 0; i < nsaved; i++)
      println("  STORE32_32 r%d, r31, %d", saved[i], -fn->stack_size - 4 * (i + 1));
    if (fn->ra_alloca)
      println("  STORE32_32 sp, r31, %d", fn->alloca_bottom->offset);

    emit_body(buf, fn->ra_asm);
    free(buf);

    // Epilogue
    for (int i = 0; i < nsaved; i++)
      println("  LOAD32_32 r%d, r31, %d", saved[i], -fn->stack_size - 4 * (i + 1));
    println("  ADDR32 sp, r31, r0");
    if (has_call)
      println("  LOAD32_32 lr, sp, 0");
    println("  LOAD32_32 r31, sp, 4");
    println("  ADDI32 sp, sp, 8");
    println("  RET32");
  }
}

void codegen(Obj *prog, FILE *out) {
  output_file = out;

  // ファイルの番号：入力ファイルのパス（tools/cc.js はリポジトリからの相対パスで渡す）の FNV-1a ハッシュ
  char *name = base_file ? base_file : "";
  uint32_t h = 2166136261u;
  for (char *p = name; *p; p++)
    h = (h ^ (unsigned char)*p) * 16777619u;
  snprintf(fid, sizeof(fid), "%08x", h);

  for (Obj *var = prog; var; var = var->next)
    hashmap_put(&globals, var->name, var);

  println("; MyCPU のアセンブリ（chibicc）：%s", base_file ? base_file : "");
  assign_lvar_offsets(prog);
  emit_data(prog);
  emit_text(prog);
}
