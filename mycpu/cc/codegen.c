// コード生成：この CPU（isa-spec.md、32bit）のアセンブリを出す。元の chibicc は x86-64 向け。
//
// 作りは元と同じ「スタックマシン」：式の値は r16 に置き、途中の値はスタックに 8 バイトずつ積む。
//   r16 = 値（x86 の rax）、r17〜r22 = 作業用、r31 = フレームポインタ（x86 の rbp）
// 型の大きさ（ILP32）：char 1、short 2、int・long・ポインタ 4、long long 8。
//   long long の値はレジスタ 2 つ（r16 = 下位、r17 = 上位）。割り算・余りは libc の __divdi3 などを呼ぶ。
//   float は 4 バイト（r16）、double・long double は 8 バイト（long long と同じく r16・r17）。どちらも IEEE 754。
//   計算・比べる・変換はどれも libc/softfloat.c の関数を呼ぶ（ソフトウェアで）。
// 呼び出し規約（isa-spec.md の 8 章）：引数は r16〜r21（7 個目からと、構造体・long long はスタック）、
//   戻り値は r16（long long・double は r16・r17）。float は int と同じ、double は long long と同じに渡す。
//   構造体を返す関数は、呼ぶ側がバッファを用意して、その番地を隠れた最初の引数として渡す。
// フレーム：[r31] = 戻り番地（lr）、[r31 + 4] = 呼んだ側の r31、[r31 + 8] 〜 = スタックで渡された引数、
//   [r31 − n] = ローカル変数。SP は常に 8 の倍数。
// 名前：C の大域の名前は「_名前」、static と内部のラベルは「L<ファイルの番号>…」（ファイルごとに別）。
//   データは「; @data」、コードは「; @text」の行で区切って出す（ドライバが分けて並べ直す）。
//   関数の前には「; @fn 名前」、大域変数の前には「; @obj 名前」（ドライバが使わないものを捨てる）。
#include "chibicc.h"

#define GP_MAX 6

static FILE *output_file;
static int depth;
static Obj *current_fn;
static HashMap globals;            // この翻訳単位の大域の名前 → Obj（static かどうかを知るため）
static char fid[16];               // ファイルの番号（ファイル名のハッシュ）

static void gen_expr(Node *node);
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

static void push(void) {
  println("  ADDI32 sp, sp, -8");
  println("  STORE32_32 r16, sp, 0");
  depth++;
}

static void pop(int reg) {
  println("  LOAD32_32 r%d, sp, 0", reg);
  println("  ADDI32 sp, sp, 8");
  depth--;
}

// long long（8 バイトの整数）か
static bool is64(Type *ty) {
  return ty->kind == TY_LONG && ty->size == 8;
}

// 64bit の値（r16 = 下位、r17 = 上位）を 1 つの 8 バイトに積む・取り出す
static void push64(void) {
  println("  ADDI32 sp, sp, -8");
  println("  STORE32_32 r16, sp, 0");
  println("  STORE32_32 r17, sp, 4");
  depth++;
}

static void pop64(int lo, int hi) {
  println("  LOAD32_32 r%d, sp, 0", lo);
  println("  LOAD32_32 r%d, sp, 4", hi);
  println("  ADDI32 sp, sp, 8");
  depth--;
}

// 8 バイトのスカラー（long long・double・long double）か。レジスタ 2 つで扱う
static bool is_pair(Type *ty) {
  return is64(ty) || ty->kind == TY_DOUBLE || ty->kind == TY_LDOUBLE;
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

static void unsupported(Node *node, Type *ty) {
  error_tok(node->tok, "この型はまだ使えない（MyCPU）");
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

// 値（型 ty）が 0 なら / 0 でなければ飛ぶ
static void jump_if_zero(Type *ty, char *label) {
  to_cmp_zero(ty);
  println("  CMPEQI32 p1, r16, 0");
  println("  BR32 p1, %s", label);
}

static void jump_if_nonzero(Type *ty, char *label) {
  to_cmp_zero(ty);
  println("  CMPNEI32 p1, r16, 0");
  println("  BR32 p1, %s", label);
}

// libc/softfloat.c の関数を 1 つの引数で呼ぶ。引数は今の値：8 バイトならスタックで、4 バイトなら r16 で渡す
static void call_helper(char *fn, bool arg8) {
  if (arg8)
    push64();
  println("  CALL32 %s", fn);
  if (arg8) {
    println("  ADDI32 sp, sp, 8");
    depth--;
  }
}

// src から dst へ size バイト写す（r20・r21 を壊す。src・dst のレジスタは変えない）
static void copy_bytes(int dst, int dst_off, int src, int size, int align) {
  if (align >= 4 && size % 4 == 0 && size <= 64) {
    for (int i = 0; i < size; i += 4) {
      println("  LOAD32_32 r20, r%d, %d", src, i);
      println("  STORE32_32 r20, r%d, %d", dst, dst_off + i);
    }
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

// Compute the absolute address of a given node.
// It's an error if a given node does not reside in memory.
static void gen_addr(Node *node) {
  switch (node->kind) {
  case ND_VAR:
    // Variable-length array, which is always local.
    if (node->var->ty->kind == TY_VLA) {
      println("  LOAD32_32 r16, r31, %d", node->var->offset);
      return;
    }

    // Local variable
    if (node->var->is_local) {
      println("  ADDI32 r16, r31, %d", node->var->offset);
      return;
    }

    // 関数・大域変数（スレッドローカルも、ただの大域変数として扱う）
    println("  ADDI32 r16, r0, %s", sym_name(node->var->name));
    return;
  case ND_DEREF:
    gen_expr(node->lhs);
    return;
  case ND_COMMA:
    gen_expr(node->lhs);
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
  switch (ty->kind) {
  case TY_ARRAY:
  case TY_STRUCT:
  case TY_UNION:
  case TY_FUNC:
  case TY_VLA:
    // If it is an array, do not attempt to load a value to the
    // register because in general we can't load an entire array to a
    // register. As a result, the result of an evaluation of an array
    // becomes not the array itself but the address of the array.
    // This is where "array is automatically converted to a pointer to
    // the first element of the array in C" occurs.
    return;
  }

  // char・short は int の大きさに広げて読む
  if (ty->size == 1)
    println("  %s r16, r16, 0", ty->is_unsigned ? "LOAD8U_32" : "LOAD8S_32");
  else if (ty->size == 2)
    println("  %s r16, r16, 0", ty->is_unsigned ? "LOAD16U_32" : "LOAD16S_32");
  else if (ty->size == 4)
    println("  LOAD32_32 r16, r16, 0");
  else if (is_pair(ty)) {
    println("  LOAD32_32 r17, r16, 4");
    println("  LOAD32_32 r16, r16, 0");
  } else
    unsupported(node, ty);
}

// Store r16 to an address that the stack top is pointing to.
static void store(Node *node, Type *ty) {
  if (is_pair(ty)) {
    pop(22);
    println("  STORE32_32 r16, r22, 0");
    println("  STORE32_32 r17, r22, 4");
    return;
  }

  pop(17);

  switch (ty->kind) {
  case TY_STRUCT:
  case TY_UNION:
    copy_bytes(17, 0, 16, ty->size, ty->align);
    return;
  }

  if (ty->size == 1)
    println("  STORE8_32 r16, r17, 0");
  else if (ty->size == 2)
    println("  STORE16_32 r16, r17, 0");
  else if (ty->size == 4)
    println("  STORE32_32 r16, r17, 0");
  else
    unsupported(node, ty);
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

  // 整数どうし：小さい型へは切り詰めて広げ直す（読むときに広げてあるので、大きい型へは何もしない）
  if (to->size == 1 && !(from->size == 1 && from->is_unsigned == to->is_unsigned)) {
    if (to->is_unsigned) {
      println("  ANDI32 r16, r16, 0xFF");
    } else {
      println("  SHLI32 r16, r16, 24");
      println("  SARI32 r16, r16, 24");
    }
  } else if (to->size == 2 && from->size > 1 && !(from->size == 2 && from->is_unsigned == to->is_unsigned)) {
    if (to->is_unsigned) {
      println("  ANDI32 r16, r16, 0xFFFF");
    } else {
      println("  SHLI32 r16, r16, 16");
      println("  SARI32 r16, r16, 16");
    }
  } else if (to->size == 2 && from->size == 1 && to->is_unsigned && !from->is_unsigned) {
    println("  ANDI32 r16, r16, 0xFFFF");
  }
}

// 構造体をスタックに写す（r16 が構造体の番地）
static void push_struct(Type *ty) {
  int sz = align_to(ty->size, 8);
  println("  ADDI32 sp, sp, -%d", sz);
  depth += sz / 8;
  println("  ADDR32 r17, sp, r0");
  copy_bytes(17, 0, 16, ty->size, ty->align);
}

static void push_args2(Node *args, bool first_pass) {
  if (!args)
    return;
  push_args2(args->next, first_pass);

  if ((first_pass && !args->pass_by_stack) || (!first_pass && args->pass_by_stack))
    return;

  gen_expr(args);

  switch (args->ty->kind) {
  case TY_STRUCT:
  case TY_UNION:
    push_struct(args->ty);
    break;
  default:
    push_val(args->ty);
  }
}

// 引数を積む。先に「スタックで渡すもの」を後ろから、次に「レジスタで渡すもの」を後ろから積むので、
// 後で取り出すと最初の引数から順に出てくる。スタックで渡すものは、そのまま呼ばれた側が読む。
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

  if (node->ret_buffer) {
    println("  ADDI32 r16, r31, %d", node->ret_buffer->offset);
    push();
  }

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

// 32bit の整数の定数か（usual_arith_conv が付けた型の変換もたどる）。*v にその値
static bool is_imm32(Node *node, int32_t *v) {
  if (node->kind == ND_CAST && is_integer(node->ty) && node->ty->size == 4)
    node = node->lhs;
  if (node->kind != ND_NUM || !is_integer(node->ty) || is64(node->ty))
    return false;
  *v = (int32_t)node->val;
  return true;
}

// 番地を作らずに 1 命令で読めるローカル変数（4 バイトの整数・ポインタ・float）か
static bool is_local32(Node *node) {
  return node->kind == ND_VAR && node->var->is_local && node->var->ty->kind != TY_VLA && node->ty->size == 4 &&
         (is_integer(node->ty) || node->ty->kind == TY_PTR || node->ty->kind == TY_FLOAT);
}

// 右が定数の演算を、即値の命令 1 つで（r16 = 左 op 定数）。できなければ false（何も出さない）
static bool gen_binary_imm(Node *node, int32_t imm, bool emit) {
  bool uns = node->lhs->ty->is_unsigned || node->lhs->ty->base;
  char *op = NULL, *cmp = NULL;
  int32_t v = imm;
  switch (node->kind) {
  case ND_ADD: op = "ADDI32"; break;
  case ND_SUB:
    if (imm == INT32_MIN)
      return false;
    op = "ADDI32";
    v = -imm;
    break;
  case ND_MUL: op = "MULI32"; break;
  case ND_DIV:
    if (imm == 0)
      return false;                    // 0 で割る例外は、今までどおり実行のときに
    op = node->ty->is_unsigned ? "DIVUI32" : "DIVI32";
    break;
  case ND_MOD:
    if (imm == 0)
      return false;
    op = node->ty->is_unsigned ? "REMUI32" : "REMI32";
    break;
  case ND_BITAND: op = "ANDI32"; break;
  case ND_BITOR: op = "ORI32"; break;
  case ND_BITXOR: op = "XORI32"; break;
  case ND_SHL:
    if (imm < 0 || imm > 31)
      return false;
    op = "SHLI32";
    break;
  case ND_SHR:
    if (imm < 0 || imm > 31)
      return false;
    op = node->lhs->ty->is_unsigned ? "SHRI32" : "SARI32";
    break;
  case ND_EQ: cmp = "CMPEQI32"; break;
  case ND_NE: cmp = "CMPNEI32"; break;
  case ND_LT: cmp = uns ? "CMPLTUI32" : "CMPLTI32"; break;
  case ND_LE:                          // a ≦ v は a < v + 1（v + 1 があふれないとき）
    if (uns ? (uint32_t)imm == UINT32_MAX : imm == INT32_MAX)
      return false;
    cmp = uns ? "CMPLTUI32" : "CMPLTI32";
    v = (int32_t)((uint32_t)imm + 1);
    break;
  default:
    return false;
  }
  if (!emit)
    return true;
  if (op) {
    println("  %s r16, r16, %d", op, v);
  } else {
    println("  %s p1, r16, %d", cmp, v);
    println("  BTOI32 r16, p1");
  }
  return true;
}

// 2 つの値の演算：r16 = 左、r17 = 右
static void gen_binary(Node *node) {
  bool uns = node->lhs->ty->is_unsigned || node->lhs->ty->base;

  switch (node->kind) {
  case ND_ADD:
    println("  ADDR32 r16, r16, r17");
    return;
  case ND_SUB:
    println("  SUBR32 r16, r16, r17");
    return;
  case ND_MUL:
    println("  MULR32 r16, r16, r17");
    return;
  case ND_DIV:
    println("  %s r16, r16, r17", node->ty->is_unsigned ? "DIVUR32" : "DIVR32");
    return;
  case ND_MOD:
    println("  %s r16, r16, r17", node->ty->is_unsigned ? "REMUR32" : "REMR32");
    return;
  case ND_BITAND:
    println("  ANDR32 r16, r16, r17");
    return;
  case ND_BITOR:
    println("  ORR32 r16, r16, r17");
    return;
  case ND_BITXOR:
    println("  XORR32 r16, r16, r17");
    return;
  case ND_EQ:
    println("  CMPEQR32 p1, r16, r17");
    println("  BTOI32 r16, p1");
    return;
  case ND_NE:
    println("  CMPNER32 p1, r16, r17");
    println("  BTOI32 r16, p1");
    return;
  case ND_LT:
    println("  %s p1, r16, r17", uns ? "CMPLTUR32" : "CMPLTR32");
    println("  BTOI32 r16, p1");
    return;
  case ND_LE:                          // a <= b は b >= a
    println("  %s p1, r17, r16", uns ? "CMPGEUR32" : "CMPGER32");
    println("  BTOI32 r16, p1");
    return;
  case ND_SHL:
    println("  SHLR32 r16, r16, r17");
    return;
  case ND_SHR:
    println("  %s r16, r16, r17", node->lhs->ty->is_unsigned ? "SHRR32" : "SARR32");
    return;
  }

  error_tok(node->tok, "invalid expression");
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

  gen_expr(node->rhs);
  push_val(node->rhs->ty);
  gen_expr(node->lhs);
  if (f32) {
    pop(17);
    println("  CALL32 %s", fn);
  } else {
    push64();
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

// Generate code for a given node.
static void gen_expr(Node *node) {
  switch (node->kind) {
  case ND_NULL_EXPR:
    return;
  case ND_NUM:
    // ビット列をそのまま入れる。NaN はいつも 0x7FC00000・0x7FF8000000000000（libc/softfloat.c と同じ。
    // PC の上で 0.0 / 0.0 を計算すると符号つきの NaN になることがあるので、そろえる）
    if (node->ty->kind == TY_FLOAT) {
      union { float f; uint32_t u; } u = { node->fval };
      if (node->fval != node->fval)
        u.u = 0x7FC00000;
      println("  ADDI32 r16, r0, %d", (int32_t)u.u);
      return;
    }
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
    if (node->ty->kind == TY_FLOAT) {           // 符号のビットを反転する
      println("  XORI32 r16, r16, %d", INT32_MIN);
      return;
    }
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
    // スカラーのローカル変数は、番地を作らずに直接読む
    if (node->var->is_local && node->var->ty->kind != TY_VLA && (is_integer(node->ty) || node->ty->kind == TY_FLOAT) &&
        node->ty->size == 4) {
      println("  LOAD32_32 r16, r31, %d", node->var->offset);
      return;
    }
    if (node->var->is_local && node->ty->kind == TY_PTR) {
      println("  LOAD32_32 r16, r31, %d", node->var->offset);
      return;
    }
    gen_addr(node);
    load(node, node->ty);
    return;
  case ND_MEMBER: {
    gen_addr(node);
    load(node, node->ty);

    Member *mem = node->member;
    if (mem->is_bitfield) {
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
    // スカラーのローカル変数へは、直接書く
    if (node->lhs->kind == ND_VAR && node->lhs->var->is_local && node->lhs->var->ty->kind != TY_VLA &&
        (is_integer(node->ty) || node->ty->kind == TY_PTR || node->ty->kind == TY_FLOAT) && node->ty->size == 4) {
      gen_expr(node->rhs);
      println("  STORE32_32 r16, r31, %d", node->lhs->var->offset);
      return;
    }

    gen_addr(node->lhs);
    push();
    gen_expr(node->rhs);

    if (node->lhs->kind == ND_MEMBER && node->lhs->member->is_bitfield) {
      // If the lhs is a bitfield, we need to read the current value
      // from memory and merge it with a new value.
      Member *mem = node->lhs->member;
      if (is64(mem->ty))
        error_tok(node->tok, "long long のビットフィールドはまだ使えない（MyCPU）");
      uint32_t field = mem->bit_width >= 32 ? 0xFFFFFFFFu : ((1u << mem->bit_width) - 1);
      uint32_t mask = field << mem->bit_offset;
      println("  ADDR32 r22, r16, r0");          // 書く値（式の値として最後に戻す）
      println("  ANDI32 r19, r16, %d", (int32_t)field);
      println("  SHLI32 r19, r19, %d", mem->bit_offset);
      println("  LOAD32_32 r16, sp, 0");         // 番地
      load(node, mem->ty);
      println("  ANDI32 r16, r16, %d", (int32_t)~mask);
      println("  ORR32 r16, r16, r19");
      store(node, node->ty);
      println("  ADDR32 r16, r22, r0");
      return;
    }

    store(node, node->ty);
    return;
  case ND_STMT_EXPR:
    for (Node *n = node->body; n; n = n->next)
      gen_stmt(n);
    return;
  case ND_COMMA:
    gen_expr(node->lhs);
    gen_expr(node->rhs);
    return;
  case ND_CAST:
    gen_expr(node->lhs);
    cast(node, node->lhs->ty, node->ty);
    return;
  case ND_MEMZERO: {
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
    int c = count();
    gen_expr(node->cond);
    jump_if_zero(node->cond->ty, format("L%s.else.%d", fid, c));
    gen_expr(node->then);
    println("  JMP32 L%s.end.%d", fid, c);
    println("L%s.else.%d:", fid, c);
    gen_expr(node->els);
    println("L%s.end.%d:", fid, c);
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
  case ND_LOGAND: {
    int c = count();
    gen_expr(node->lhs);
    jump_if_zero(node->lhs->ty, format("L%s.false.%d", fid, c));
    gen_expr(node->rhs);
    jump_if_zero(node->rhs->ty, format("L%s.false.%d", fid, c));
    println("  ADDI32 r16, r0, 1");
    println("  JMP32 L%s.end.%d", fid, c);
    println("L%s.false.%d:", fid, c);
    println("  ADDI32 r16, r0, 0");
    println("L%s.end.%d:", fid, c);
    return;
  }
  case ND_LOGOR: {
    int c = count();
    gen_expr(node->lhs);
    jump_if_nonzero(node->lhs->ty, format("L%s.true.%d", fid, c));
    gen_expr(node->rhs);
    jump_if_nonzero(node->rhs->ty, format("L%s.true.%d", fid, c));
    println("  ADDI32 r16, r0, 0");
    println("  JMP32 L%s.end.%d", fid, c);
    println("L%s.true.%d:", fid, c);
    println("  ADDI32 r16, r0, 1");
    println("L%s.end.%d:", fid, c);
    return;
  }
  case ND_FUNCALL: {
    if (node->lhs->kind == ND_VAR && !strcmp(node->lhs->var->name, "alloca")) {
      gen_expr(node->args);
      println("  ADDR32 r17, r16, r0");
      builtin_alloca();
      return;
    }

    int stack_args = push_args(node);

    // 名前の決まった関数は直接 CALL32。関数ポインタは r22 に入れて CALLR32
    bool direct = node->lhs->kind == ND_VAR && !node->lhs->var->is_local && node->lhs->var->ty->kind == TY_FUNC;
    if (!direct) {
      gen_expr(node->lhs);
      println("  ADDR32 r22, r16, r0");
    }

    int gp = 0;
    if (node->ret_buffer)
      pop(16 + gp++);
    for (Node *arg = node->args; arg; arg = arg->next)
      if (!arg->pass_by_stack)
        pop(16 + gp++);

    if (direct)
      println("  CALL32 %s", sym_name(node->lhs->var->name));
    else
      println("  CALLR32 r22");

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

  // 32bit どうしで、右が定数なら即値の命令で、4 バイトのローカル変数なら積まずに r17 へ直接読む
  // （どちらも副作用がないので、左を先に求めても結果は同じ）
  if (!is64(node->lhs->ty) && !is64(node->rhs->ty)) {
    int32_t imm;
    if (is_imm32(node->rhs, &imm) && gen_binary_imm(node, imm, false)) {
      gen_expr(node->lhs);
      gen_binary_imm(node, imm, true);
      return;
    }
    if (is_local32(node->rhs)) {
      gen_expr(node->lhs);
      println("  LOAD32_32 r17, r31, %d", node->rhs->var->offset);
      gen_binary(node);
      return;
    }
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
    int c = count();
    gen_expr(node->cond);
    jump_if_zero(node->cond->ty, format("L%s.else.%d", fid, c));
    gen_stmt(node->then);
    println("  JMP32 L%s.end.%d", fid, c);
    println("L%s.else.%d:", fid, c);
    if (node->els)
      gen_stmt(node->els);
    println("L%s.end.%d:", fid, c);
    return;
  }
  case ND_FOR: {
    int c = count();
    if (node->init)
      gen_stmt(node->init);
    println("L%s.begin.%d:", fid, c);
    if (node->cond) {
      gen_expr(node->cond);
      jump_if_zero(node->cond->ty, sym_name(node->brk_label));
    }
    gen_stmt(node->then);
    println("%s:", sym_name(node->cont_label));
    if (node->inc)
      gen_expr(node->inc);
    println("  JMP32 L%s.begin.%d", fid, c);
    println("%s:", sym_name(node->brk_label));
    return;
  }
  case ND_DO: {
    int c = count();
    println("L%s.begin.%d:", fid, c);
    gen_stmt(node->then);
    println("%s:", sym_name(node->cont_label));
    gen_expr(node->cond);
    jump_if_nonzero(node->cond->ty, format("L%s.begin.%d", fid, c));
    println("%s:", sym_name(node->brk_label));
    return;
  }
  case ND_SWITCH:
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
        println("  CMPEQI32 p1, r16, %d", (int32_t)n->begin);
        println("  BR32 p1, %s", sym_name(n->label));
        continue;
      }

      // [GNU] Case ranges：begin ≦ 値 ≦ end は（値 − begin）≦（end − begin）（符号なし）
      println("  ADDI32 r17, r16, %d", (int32_t)-n->begin);
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
    gen_expr(node->lhs);
    println("  JMPR32 r16");
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
        println("  LOAD32_32 r17, r31, %d", current_fn->params->offset);
        copy_bytes(17, 0, 16, ty->size, ty->align);
      }
    }

    println("  JMP32 L%s.ret.%s", fid, current_fn->name);
    return;
  case ND_EXPR_STMT:
    gen_expr(node->lhs);
    return;
  case ND_ASM:
    println("  %s", node->asm_str);
    return;
  }

  error_tok(node->tok, "invalid statement");
}

// Assign offsets to local variables.
static void assign_lvar_offsets(Obj *prog) {
  for (Obj *fn = prog; fn; fn = fn->next) {
    if (!fn->is_function)
      continue;

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

    // レジスタで渡された引数とローカル変数
    for (Obj *var = fn->locals; var; var = var->next) {
      if (var->offset)
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

static void store_gp(int r, int offset, int sz) {
  switch (sz) {
  case 1:
    println("  STORE8_32 r%d, r31, %d", 16 + r, offset);
    return;
  case 2:
    println("  STORE16_32 r%d, r31, %d", 16 + r, offset);
    return;
  case 4:
    println("  STORE32_32 r%d, r31, %d", 16 + r, offset);
    return;
  }
  unreachable();
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

    println("; @fn %s", sym_name(fn->name));
    println("%s:", sym_name(fn->name));
    current_fn = fn;

    // Prologue：lr と r31 を積み、r31 をフレームの基準にして、ローカル変数の分だけ SP を下げる
    println("  ADDI32 sp, sp, -8");
    println("  STORE32_32 lr, sp, 0");
    println("  STORE32_32 r31, sp, 4");
    println("  ADDR32 r31, sp, r0");
    if (fn->stack_size)
      println("  ADDI32 sp, sp, %d", -fn->stack_size);
    println("  STORE32_32 sp, r31, %d", fn->alloca_bottom->offset);

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

    // Save passed-by-register arguments to the stack
    int gp = 0;
    for (Obj *var = fn->params; var; var = var->next) {
      if (var->offset > 0)
        continue;
      store_gp(gp++, var->offset, var->ty->size);
    }

    // Emit code
    gen_stmt(fn->body);
    assert(depth == 0);

    // [https://www.sigbus.info/n1570#5.1.2.2.3p1] The C spec defines
    // a special rule for the main function. Reaching the end of the
    // main function is equivalent to returning 0, even though the
    // behavior is undefined for the other functions.
    if (strcmp(fn->name, "main") == 0)
      println("  ADDI32 r16, r0, 0");

    // Epilogue
    println("L%s.ret.%s:", fid, fn->name);
    println("  ADDR32 sp, r31, r0");
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
