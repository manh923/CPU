// AS.EXE — この CPU のアセンブラ（C で書いたもの。lib/assembler.js と同じ書き方で、同じバイト列を作る）
//   AS [-o OUT.EXE] [-b 番地] [-bin OUT.BIN] [-lib 名前] FILE.S ...
//     -o    .EXE（MZ ヘッダ。読み込む番地 = いちばん小さい番地、開始番地 = ラベル start）を作る
//     -bin  そのままのバイト列（いちばん小さい番地から）を作る
//     -b    最初の番地（なければ 0。C のプログラムは 0x1000000 = SDRAM）
//     -lib  先にアセンブルしてあるライブラリ（名前.BIN と、名前と番地の表 名前.SYM。tools/cc.js が作る）を使う：
//           表の名前を知っている状態でアセンブルし、名前.BIN の後ろ（-b がなければそこから）にプログラムを置く。
//           .EXE には、ライブラリのうちプログラムが使う関数・変数（名前.SYM の @chunk。使うものからたどれるものも）
//           だけを入れる（区切りのある .EXE。ライブラリは動かさないので、番地はとびとび）。-bin には名前.BIN を全部入れる。
//           弱いかたまり（@chunk の w）は、プログラムが名前で使ったときだけ中身を入れ、ほかは 0 で埋める（先もたどらない）
//           プログラムで同じ名前を定義すれば、プログラムの方を使う
// ファイルをいくつも渡すと、1 つのプログラムにまとめる（リンカの代わり。tools/cc.js と同じ並べ方）：
//   「; @text」「; @data」の行で分けてあれば、全部のファイルのコードを前に、データを後ろにまとめ、
//   「; @common 名前 大きさ 揃え」（初期値なしの大域変数）は、どこにも定義がなければ 1 つだけ置き、
//   最後に ___heap_start（malloc が使い始める番地）を置く。
// 行を全部は覚えず、ファイルを 2 回読む（1 回目で番地とラベルを決め、2 回目でバイト列を作る）。
// MyDOS でも PC でも（gcc でも）コンパイルできる。エラーは英語（MyCPU の文字は ASCII だけ）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>

#include "asops.h"

typedef long long i64;
typedef unsigned long long u64;

// ---- エラー ----
static char *cur_file;
static int cur_line;
static int nerrors;
static char errmsg[200];
static int has_err;              // この行でエラーがあった

static void err(const char *fmt, const char *arg) {
  if (has_err)
    return;
  has_err = 1;
  snprintf(errmsg, sizeof(errmsg), fmt, arg ? arg : "");
  fprintf(stderr, "%s:%d: %s\n", cur_file, cur_line, errmsg);
  nerrors++;
}

// ---- 名前の表（ハッシュ） ----
typedef struct {
  char *name;
  i64 value;
  int lib;                       // -lib の表から（プログラムで定義し直してよい）
  int used;                      // プログラムが使った（-lib の名前のとき）
} Sym;

static Sym *syms;
static int nsyms, cap_syms;

static unsigned hash(const char *s) {
  unsigned h = 2166136261u;
  for (; *s; s++)
    h = (h ^ (unsigned char)*s) * 16777619u;
  return h;
}

static Sym *find_slot(const char *name) {
  unsigned i = hash(name) & (cap_syms - 1);
  for (;;) {
    if (!syms[i].name || !strcmp(syms[i].name, name))
      return &syms[i];
    i = (i + 1) & (cap_syms - 1);
  }
}

static Sym *lookup_sym(const char *name) {
  if (!cap_syms)
    return 0;
  Sym *s = find_slot(name);
  return s->name ? s : 0;
}

static void grow_syms(void) {
  Sym *old = syms;
  int old_cap = cap_syms;
  cap_syms = cap_syms ? cap_syms * 2 : 1024;
  syms = calloc(cap_syms, sizeof(Sym));
  for (int i = 0; i < old_cap; i++)
    if (old[i].name)
      *find_slot(old[i].name) = old[i];
  free(old);
}

static void define(const char *name, i64 value) {
  if ((nsyms + 1) * 2 > cap_syms)
    grow_syms();
  Sym *s = find_slot(name);
  if (s->name && s->lib) {         // ライブラリの名前は、プログラムの定義で置き換える
    s->value = value;
    s->lib = 0;
    return;
  }
  if (s->name) {
    err("duplicate symbol: %s", name);
    return;
  }
  s->name = strdup(name);
  s->value = value;
  nsyms++;
}

// ---- 状態 ----
static int pass;                 // 1 = 番地とラベルを決める、2 = バイト列を作る
static i64 pc;                   // 次に置く番地
static i64 delta;                // .phase 中は「動く番地 − 置く番地」
static char scope[256];          // '.' で始まるラベルの持ち主（直前の '.' でないラベル）
static i64 lo = -1, hi;          // 1 回目：中身のある番地の範囲
static unsigned char *image;     // 2 回目：[lo, hi) のバイト列
static i64 base;                 // -b

// s の先頭 len 文字を out（大きさ n）に、0 で終わる文字列として写す（入らない分は捨てる）
// （1 行ごとに何度も呼ぶので snprintf は使わない。遅い）
static void copy_str(char *out, int n, const char *s, int len) {
  if (len > n - 1)
    len = n - 1;
  memcpy(out, s, len);
  out[len] = 0;
}

// '.' で始まる名前は「持ち主.名前」に
static void qualify(const char *name, char *out, int n) {
  int k = 0;
  if (name[0] == '.') {
    k = strlen(scope);
    copy_str(out, n, scope, k);
    if (k > n - 1)
      k = n - 1;
  }
  copy_str(out + k, n - k, name, strlen(name));
}

// 中身を置く（1 回目は範囲だけ、2 回目は書く）
static void emit(const unsigned char *b, int n) {
  if (pass == 1) {
    if (n > 0) {
      if (lo < 0 || pc < lo)
        lo = pc;
      if (pc + n > hi)
        hi = pc + n;
    }
  } else if (n > 0) {
    if (pc < lo || pc + n > hi)
      err("internal: address out of range", 0);
    else
      memcpy(image + (pc - lo), b, n);
  }
  pc += n;
}

static void emit_le(u64 v, int n) {
  unsigned char b[8];
  for (int i = 0; i < n; i++) {
    b[i] = v & 0xff;
    v >>= 8;
  }
  emit(b, n);
}

// ---- 文字列（"..."） ----
static int unescape(char e) {
  switch (e) {
  case 'n': return 10;
  case 'r': return 13;
  case 't': return 9;
  case '0': return 0;
  case '\\': return 92;
  case '"': return 34;
  case '\'': return 39;
  case 'a': return 7;
  case 'b': return 8;
  case 'e': return 27;
  }
  return -1;
}

static int hexval(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// "..." を out に。戻り値はバイト数（-1 = エラー）
static int parse_string(const char *tok, unsigned char *out, int max) {
  int len = strlen(tok);
  if (len < 2 || tok[0] != '"' || tok[len - 1] != '"') {
    err("string must be \"...\": %s", tok);
    return -1;
  }
  int n = 0;
  for (int i = 1; i < len - 1; i++) {
    int c = (unsigned char)tok[i];
    if (c == '\\') {
      char e = tok[++i];
      if (e == 'x') {
        c = hexval(tok[i + 1]) * 16 + hexval(tok[i + 2]);
        i += 2;
      } else {
        c = unescape(e);
        if (c < 0) {
          char b[3] = {'\\', e, 0};
          err("unknown escape: %s", b);
          return -1;
        }
      }
    }
    if (n < max)
      out[n] = c;
    n++;
  }
  return n;
}

// ---- 式（64bit） ----
static const char *ep;           // 読んでいる所
static int unknown;              // まだ決まっていない名前を使った
static int expr_err;

static void skip_sp(void) {
  while (*ep == ' ' || *ep == '\t')
    ep++;
}

static int is_id_start(int c) { return isalpha(c) || c == '_' || c == '.'; }
static int is_id(int c) { return isalnum(c) || c == '_' || c == '.'; }

static i64 binary(int min_prec);

static i64 unary(void) {
  skip_sp();
  char c = *ep;
  if (!c) {
    expr_err = 1;
    return 0;
  }
  if (isdigit((unsigned char)c)) {
    u64 v = 0;
    int base = 10;
    if (c == '0' && (ep[1] == 'x' || ep[1] == 'X')) {
      base = 16;
      ep += 2;
    } else if (c == '0' && (ep[1] == 'b' || ep[1] == 'B')) {
      base = 2;
      ep += 2;
    }
    for (;; ep++) {
      if (*ep == '_')
        continue;
      int d = hexval(*ep);
      if (d < 0 || d >= base)
        break;
      v = v * base + d;
    }
    if (is_id(*ep))
      expr_err = 1;
    return (i64)v;
  }
  if (c == '\'') {                     // 'A'、'\n'、'\x41'
    int v;
    if (ep[1] == '\\') {
      if (ep[2] == 'x') {
        v = hexval(ep[3]) * 16 + hexval(ep[4]);
        ep += 5;
      } else {
        v = unescape(ep[2]);
        ep += 3;
      }
    } else {
      v = (unsigned char)ep[1];
      ep += 2;
    }
    if (*ep != '\'' || v < 0) {
      expr_err = 1;
      return 0;
    }
    ep++;
    return v;
  }
  if (is_id_start((unsigned char)c)) {
    char name[256], q[512];
    int n = 0;
    while (is_id((unsigned char)*ep) && n < 255)
      name[n++] = *ep++;
    name[n] = 0;
    qualify(name, q, sizeof(q));
    Sym *s = lookup_sym(q);
    if (!s) {
      unknown = 1;
      return 0;
    }
    s->used = 1;
    return s->value;
  }
  ep++;
  if (c == '-') return -unary();
  if (c == '+') return unary();
  if (c == '~') return ~unary();
  if (c == '(') {
    i64 v = binary(0);
    skip_sp();
    if (*ep != ')') {
      expr_err = 1;
      return 0;
    }
    ep++;
    return v;
  }
  expr_err = 1;
  return 0;
}

// 次の演算子と優先順位（なければ 0）
static int peek_op(int *len) {
  skip_sp();
  *len = 1;
  switch (*ep) {
  case '|': return 1;
  case '^': return 2;
  case '&': return 3;
  case '<': if (ep[1] == '<') { *len = 2; return 4; } return 0;
  case '>': if (ep[1] == '>') { *len = 2; return 4; } return 0;
  case '+': case '-': return 5;
  case '*': case '/': case '%': return 6;
  }
  return 0;
}

static i64 binary(int min_prec) {
  i64 lhs = unary();
  for (;;) {
    int len, prec = peek_op(&len);
    if (!prec || prec <= min_prec)
      return lhs;
    char op = *ep;
    ep += len;
    i64 rhs = binary(prec);
    switch (op) {
    case '+': lhs += rhs; break;
    case '-': lhs -= rhs; break;
    case '*': lhs *= rhs; break;
    case '/':
    case '%':
      if (!rhs) {
        if (!unknown)
          expr_err = 2;
        break;
      }
      lhs = op == '/' ? lhs / rhs : lhs % rhs;
      break;
    case '<': lhs = (i64)((u64)lhs << rhs); break;
    case '>': lhs >>= rhs; break;
    case '&': lhs &= rhs; break;
    case '|': lhs |= rhs; break;
    case '^': lhs ^= rhs; break;
    }
  }
}

// 式を求める。戻り値 1 = 値が決まった、0 = まだ決まらない名前がある（*v は 0）、-1 = エラー
static int eval(const char *s, i64 *v) {
  ep = s;
  unknown = expr_err = 0;
  skip_sp();
  if (!*ep) {
    err("empty expression", 0);
    return -1;
  }
  *v = binary(0);
  skip_sp();
  if (expr_err == 2) {
    err("division by zero: %s", s);
    return -1;
  }
  if (expr_err || *ep) {
    err("bad expression: %s", s);
    return -1;
  }
  return unknown ? 0 : 1;
}

// 今決まっていないといけない値（.org・.align・.space・.equ など）
static int eval_now(const char *s, i64 *v) {
  int r = eval(s, v);
  if (r == 0)
    err("value must be defined before here: %s", s);
  return r == 1;
}

// 2 回目：全部決まっているはずの値
static int eval_final(const char *s, i64 *v) {
  int r = eval(s, v);
  if (r == 0)
    err("undefined symbol: %s", s);
  return r == 1;
}

static int check_range(i64 v, int bits, const char *text) {
  if (bits < 64) {
    i64 lo_ = -((i64)1 << (bits - 1)), hi_ = ((i64)1 << bits) - 1;
    if (v < lo_ || v > hi_) {
      char b[160];
      snprintf(b, sizeof(b), "%s does not fit in %d bits", text, bits);
      err("%s", b);
      return 0;
    }
  }
  return 1;
}

// ---- 1 行を分ける ----
#define MAX_OPS 64
static char *ops[MAX_OPS];
static int nops;

// ';' から後ろを捨てる（文字列・文字の中は別）
static void strip_comment(char *s) {
  char q = 0;
  for (; *s; s++) {
    if (q) {
      if (*s == '\\' && s[1])
        s++;
      else if (*s == q)
        q = 0;
    } else if (*s == '"' || *s == '\'') {
      q = *s;
    } else if (*s == ';') {
      *s = 0;
      return;
    }
  }
}

static char *trim(char *s) {
  while (*s == ' ' || *s == '\t')
    s++;
  char *e = s + strlen(s);
  while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r' || e[-1] == '\n'))
    e--;
  *e = 0;
  return s;
}

// オペランドを ',' で分ける（文字列・括弧の中の ',' は別）。s は書き換える
static void split_ops(char *s) {
  nops = 0;
  char q = 0;
  int depth = 0;
  char *start = s;
  int any = 0;
  for (; *s; s++) {
    if (q) {
      if (*s == '\\' && s[1])
        s++;
      else if (*s == q)
        q = 0;
    } else if (*s == '"' || *s == '\'') {
      q = *s;
    } else if (*s == '(') {
      depth++;
    } else if (*s == ')') {
      depth--;
    } else if (*s == ',' && depth == 0) {
      *s = 0;
      if (nops < MAX_OPS)
        ops[nops++] = trim(start);
      start = s + 1;
      any = 1;
    }
  }
  char *last = trim(start);
  if (*last || any)
    if (nops < MAX_OPS)
      ops[nops++] = last;
}

// ---- レジスタ ----
static int parse_reg(const char *t) {
  char b[16];
  int n = 0;
  for (; t[n] && n < 15; n++)
    b[n] = tolower((unsigned char)t[n]);
  b[n] = 0;
  if (t[n])
    return -1;
  static char *special[] = {"pc", "sp", "lr", "epc", "cause", "evec", "status"};
  for (int i = 0; i < 7; i++)
    if (!strcmp(b, special[i]))
      return 48 + i;
  if (b[0] == 'r' && isdigit((unsigned char)b[1])) {
    int v = 0;
    for (char *p = b + 1; *p; p++) {
      if (!isdigit((unsigned char)*p))
        return -1;
      v = v * 10 + (*p - '0');
      if (v > 999)
        return -1;
    }
    return v < 64 ? v : -1;
  }
  if (b[0] == 'p' && b[1] >= '1' && b[1] <= '7' && !b[2])
    return b[1] - '0';
  return -1;
}

static char *reg_kind(int n) {
  if (n == 0) return "zero";
  if (n < 8) return "p";
  if (n < 16) return "reserved";
  if (n < 32) return "r32";
  if (n < 48) return "r64";
  if (n == 48) return "pc";
  if (n <= 54) return "special";
  return "reserved";
}

// 使えなければ理由（英語）、使えれば NULL
static char *check_reg(int cls, int n, int wbits, int is_dest) {
  static char b[80];
  char *k = reg_kind(n);
  if (!strcmp(k, "reserved")) { snprintf(b, sizeof(b), "r%d is reserved", n); return b; }
  if (is_dest && !strcmp(k, "pc")) return "cannot write to pc";
  if (!strcmp(k, "zero")) return 0;
  switch (cls) {
  case 3: return !strcmp(k, "p") ? 0 : "not a 1-bit register";
  case 2: return !strcmp(k, "p") ? "1-bit register cannot be an address" : 0;
  case 4: return !strcmp(k, "r32") ? 0 : "not a 32-bit register";
  case 5: return !strcmp(k, "r64") ? 0 : "not a 64-bit register";
  }
  if (!strcmp(k, "pc") || !strcmp(k, "special")) return 0;
  if (!strcmp(k, "r32") && wbits == 32) return 0;
  if (!strcmp(k, "r64") && wbits == 64) return 0;
  snprintf(b, sizeof(b), "register not usable in a %d-bit instruction", wbits);
  return b;
}

// 命令の名前 → 表の行。はじめて呼ばれたときにハッシュ表を作る（1 行ごとに 173 個と比べると遅いので）
#define OP_SLOTS 512
static AsOp *op_slot[OP_SLOTS];
static int op_ready;

static unsigned op_hash(const char *s) {
  unsigned h = 2166136261u;
  for (; *s; s++)
    h = (h ^ (unsigned char)*s) * 16777619u;
  return h;
}

static AsOp *find_op(const char *mn) {
  if (!op_ready) {
    op_ready = 1;
    for (int i = 0; i < NUM_AS_OPS; i++) {
      unsigned h = op_hash(as_ops[i].name) & (OP_SLOTS - 1);
      while (op_slot[h])
        h = (h + 1) & (OP_SLOTS - 1);
      op_slot[h] = &as_ops[i];
    }
  }
  char b[32];
  int n = 0;
  for (; mn[n] && n < 31; n++)
    b[n] = toupper((unsigned char)mn[n]);
  b[n] = 0;
  for (unsigned h = op_hash(b) & (OP_SLOTS - 1); op_slot[h]; h = (h + 1) & (OP_SLOTS - 1))
    if (!strcmp(op_slot[h]->name, b))
      return op_slot[h];
  return 0;
}

// ---- ラベル（直後が命令なら 4 バイト境界にそろえてから決める） ----
#define MAX_PENDING 64
static char *pending[MAX_PENDING];
static int npending;

static void flush_labels(void) {
  for (int i = 0; i < npending; i++) {
    if (pending[i][0] != '.')
      copy_str(scope, sizeof(scope), pending[i], strlen(pending[i]));
    if (pass == 1) {
      char q[512];
      qualify(pending[i], q, sizeof(q));
      define(q, pc + delta);
    }
    free(pending[i]);
  }
  npending = 0;
}

// ---- 命令 ----
static void do_insn(AsOp *op) {
  pc = (pc + 3) & ~3LL;
  flush_labels();
  if (pass == 1) {
    emit(0, op->len);
    return;
  }
  if (nops != op->nops) {
    err("wrong number of operands for %s", op->name);
    pc += op->len;
    return;
  }
  int f[3] = {0, 0, 0};
  i64 imm = 0;
  for (int i = 0; i < nops; i++) {
    int cls = op->spec[i] >> 4, field = op->spec[i] & 15;
    if (cls == 0) {
      if (!eval_final(ops[i], &imm) || !check_range(imm, op->wbits, ops[i])) {
        pc += op->len;
        return;
      }
      continue;
    }
    int n = parse_reg(ops[i]);
    if (n < 0) {
      err("not a register: %s", ops[i]);
      pc += op->len;
      return;
    }
    char *why = check_reg(cls, n, op->wbits, field == 0);
    if (why) {
      char b[160];
      snprintf(b, sizeof(b), "%s: %s (%s)", op->name, why, ops[i]);
      err("%s", b);
      pc += op->len;
      return;
    }
    if (field == 3)
      imm = n;
    else
      f[field] = n;
  }
  emit_le((unsigned)op->opcode | ((unsigned)f[0] << 14) | ((unsigned)f[1] << 20) | ((unsigned)f[2] << 26), 4);
  if (op->wbits)
    emit_le(imm, op->wbits / 8);
}

// ---- 疑似命令 ----
static void do_dir(char *dir) {
  for (char *p = dir; *p; p++)
    *p = tolower((unsigned char)*p);
  i64 v;

  if (!strcmp(dir, ".phase")) {
    flush_labels();
    if (nops != 1) { err(".phase address", 0); return; }
    if (delta) { err(".phase inside .phase", 0); return; }
    if (!eval_now(ops[0], &v)) return;
    delta = v - pc;
    if (delta % 16) err(".phase address must be 16-byte aligned with the current address (.align 16 first)", 0);
    return;
  }
  if (!strcmp(dir, ".dephase")) {
    flush_labels();
    delta = 0;
    return;
  }
  flush_labels();
  if (!strcmp(dir, ".org")) {
    if (delta) { err(".org inside .phase", 0); return; }
    if (nops != 1 || !eval_now(ops[0], &v)) return;
    if (v < pc) { err(".org cannot go backwards", 0); return; }
    pc = v;
    return;
  }
  if (!strcmp(dir, ".align")) {
    if (nops != 1 || !eval_now(ops[0], &v)) return;
    if (v <= 0) { err(".align must be 1 or more", 0); return; }
    i64 to = (pc + v - 1) / v * v;
    while (pc < to)
      emit_le(0, 1);
    return;
  }
  if (!strcmp(dir, ".reserve")) {
    if (nops != 1 || !eval_now(ops[0], &v)) return;
    pc += v;
    return;
  }
  if (!strcmp(dir, ".space")) {
    i64 fill = 0;
    if (nops < 1 || nops > 2 || !eval_now(ops[0], &v)) return;
    if (nops == 2 && !eval_now(ops[1], &fill)) return;
    if (pass == 1) {
      emit(0, (int)v);
    } else {
      unsigned char b = fill & 0xff;
      for (i64 i = 0; i < v; i++)
        emit(&b, 1);
    }
    return;
  }
  if (!strcmp(dir, ".ascii") || !strcmp(dir, ".asciz")) {
    for (int i = 0; i < nops; i++) {
      int n = parse_string(ops[i], 0, 0);
      if (n < 0) return;
      unsigned char *b = malloc(n + 1);
      parse_string(ops[i], b, n);
      emit(b, n);
      free(b);
    }
    if (dir[5] == 'z')
      emit_le(0, 1);
    return;
  }
  int w = !strcmp(dir, ".byte") ? 1 : !strcmp(dir, ".half") ? 2 : !strcmp(dir, ".word") ? 4 : !strcmp(dir, ".dword") ? 8 : 0;
  if (!w) {
    err("unknown directive: %s", dir);
    return;
  }
  if (!nops) {
    err("%s needs a value", dir);
    return;
  }
  for (int i = 0; i < nops; i++) {
    if (ops[i][0] == '"') {
      if (w != 1) { err("strings only in .byte or .ascii", 0); return; }
      int n = parse_string(ops[i], 0, 0);
      if (n < 0) return;
      unsigned char *b = malloc(n + 1);
      parse_string(ops[i], b, n);
      emit(b, n);
      free(b);
      continue;
    }
    if (pass == 1) {
      emit(0, w);
      continue;
    }
    if (!eval_final(ops[i], &v) || !check_range(v, w * 8, ops[i])) {
      pc += w;
      continue;
    }
    emit_le(v, w);
  }
}

// ---- 1 行 ----
static void do_line(char *line) {
  has_err = 0;
  strip_comment(line);
  char *s = line;

  // ラベル（いくつでも）
  for (;;) {
    char *p = s;
    while (*p == ' ' || *p == '\t')
      p++;
    if (!is_id_start((unsigned char)*p))
      break;
    char *q = p;
    while (is_id((unsigned char)*q))
      q++;
    char *r = q;
    while (*r == ' ' || *r == '\t')
      r++;
    if (*r != ':' || r[1] == ':')
      break;
    if (npending < MAX_PENDING)
      pending[npending++] = strndup(p, q - p);
    s = r + 1;
  }

  s = trim(s);
  if (!*s)
    return;

  // 名前 = 式
  if (isalpha((unsigned char)*s) || *s == '_') {
    char *p = s;
    while (is_id((unsigned char)*p))
      p++;
    char *eq = p;
    while (*eq == ' ' || *eq == '\t')
      eq++;
    if (*eq == '=') {
      char name[256];
      copy_str(name, sizeof(name), s, p - s);
      char *expr = trim(eq + 1);
      if (!*expr) {
        err("bad line: %s", s);
        return;
      }
      if (pass == 1) {
        i64 v;
        if (eval_now(expr, &v)) {
          char q[512];
          qualify(name, q, sizeof(q));
          define(q, v);
        }
      }
      return;
    }
  }

  // 命令か疑似命令
  if (!(isalpha((unsigned char)*s) || *s == '_' || (*s == '.' && (isalpha((unsigned char)s[1]) || s[1] == '_')))) {
    err("bad line: %s", s);
    return;
  }
  char *p = s + (*s == '.');
  while (is_id((unsigned char)*p))
    p++;
  char name[64];
  copy_str(name, sizeof(name), s, p - s);
  split_ops(p);

  if (name[0] == '.') {
    if (!strcmp(name, ".equ") || !strcmp(name, ".set") || !strcmp(name, ".EQU") || !strcmp(name, ".SET")) {
      if (nops != 2) {
        err("%s NAME, value", name);
        return;
      }
      if (pass == 1) {
        i64 v;
        if (eval_now(ops[1], &v)) {
          char q[512];
          qualify(ops[0], q, sizeof(q));
          define(q, v);
        }
      }
      return;
    }
    do_dir(name);
    return;
  }

  AsOp *op = find_op(name);
  if (!op) {
    err("unknown instruction: %s", name);
    return;
  }
  do_insn(op);
}

// ---- ファイル ----
#define MAX_FILES 64
static char *files[MAX_FILES];
static int nfiles;
static int link_mode;            // 「; @data」があった（コードとデータを分けて並べる）

// 共通の変数（; @common）
typedef struct {
  char *name;
  int size, align;
  int place;                     // 置く（1 回目に、ほかに定義がなかった）
} Common;
static Common commons[1024];
static int ncommons;

// 「名前 大きさ 揃え」
static void add_common(char *rest) {
  char name[256];
  int n = 0;
  while (*rest && *rest != ' ' && n < 255)
    name[n++] = *rest++;
  name[n] = 0;
  char *end;
  int size = strtol(rest, &end, 10);
  int align = strtol(end, &end, 10);
  if (!n || size <= 0)
    return;
  for (int i = 0; i < ncommons; i++) {
    if (!strcmp(commons[i].name, name)) {
      if (size > commons[i].size) commons[i].size = size;
      if (align > commons[i].align) commons[i].align = align;
      return;
    }
  }
  if (ncommons < 1024) {
    commons[ncommons].name = strdup(name);
    commons[ncommons].size = size;
    commons[ncommons].align = align < 4 ? 4 : align;
    ncommons++;
  }
}

static char line[4096];
static int nlines;                      // 1 回目に読んだ行の数（途中経過の表示用）

// ファイルを読み、want（0 = コード、1 = データ）の部分の行を処理する
static void do_file(char *name, int want) {
  FILE *fp = fopen(name, "r");
  if (!fp) {
    fprintf(stderr, "%s: cannot open\n", name);
    nerrors++;
    return;
  }
  cur_file = name;
  cur_line = 0;
  int section = 0;
  while (fgets(line, sizeof(line), fp)) {
    cur_line++;
    if (pass == 1 && want == 0)
      nlines++;
    if (!strncmp(line, "; @data", 7)) {
      section = 1;
      link_mode = 1;
      continue;
    }
    if (!strncmp(line, "; @text", 7)) {
      section = 0;
      continue;
    }
    if (section != want)
      continue;
    if (want == 1 && pass == 1 && !strncmp(line, "; @common ", 10)) {
      add_common(line + 10);
      continue;
    }
    do_line(line);
  }
  fclose(fp);
}

static void run_pass(int p) {
  pass = p;
  pc = base;
  delta = 0;
  scope[0] = 0;
  npending = 0;
  for (int i = 0; i < nfiles; i++)
    do_file(files[i], 0);
  if (!link_mode) {
    flush_labels();
    return;
  }
  // データ：64 バイト境界から
  cur_file = "(link)";
  strcpy(line, "        .align 64");
  do_line(line);
  for (int i = 0; i < nfiles; i++)
    do_file(files[i], 1);
  cur_file = "(link)";
  // 共通の変数：1 回目に、ほかに定義がなかったものだけ置く（2 回目も同じもの）
  for (int i = 0; i < ncommons; i++) {
    if (pass == 1)
      commons[i].place = !lookup_sym(commons[i].name);
    if (!commons[i].place)
      continue;
    snprintf(line, sizeof(line), "        .align %d", commons[i].align);
    do_line(line);
    snprintf(line, sizeof(line), "%s:", commons[i].name);
    do_line(line);
    snprintf(line, sizeof(line), "        .space %d", commons[i].size);
    do_line(line);
  }
  strcpy(line, "        .align 8");
  do_line(line);
  strcpy(line, "___heap_start:");
  do_line(line);
  flush_labels();
}

// ---- -lib ----
static char *lib_name;
static i64 lib_base = -1, lib_end;

// ライブラリのかたまり（関数・変数）：番地の範囲 [ck_start, ck_end) と、使うかたまりの番号 deps[ck_dep[i] .. ck_dep[i + 1])
static int nchunks, cap_chunks;
static i64 *ck_start, *ck_end;
static int *ck_dep;
static char *ck_weak;
static char *ck_used;            // 1 = 入れる、2 = 0 で埋めて入れる（弱いかたまりを、ほかのかたまりが使うだけ）
static int *deps, ndeps, cap_deps;

// 「@chunk 始め 終わり 番号 …」の「始め」から後ろ
static void add_chunk(char *p) {
  if (nchunks + 2 > cap_chunks) {
    cap_chunks = cap_chunks ? cap_chunks * 2 : 1024;
    ck_start = realloc(ck_start, cap_chunks * sizeof(i64));
    ck_end = realloc(ck_end, cap_chunks * sizeof(i64));
    ck_dep = realloc(ck_dep, (cap_chunks + 1) * sizeof(int));
    ck_weak = realloc(ck_weak, cap_chunks);
  }
  ck_start[nchunks] = (i64)strtoul(p, &p, 16);
  ck_end[nchunks] = (i64)strtoul(p, &p, 16);
  ck_dep[nchunks] = ndeps;
  while (*p == ' ')
    p++;
  ck_weak[nchunks] = *p == 'w';
  if (*p == 'w')
    p++;
  for (;;) {
    while (*p == ' ')
      p++;
    if (!isdigit((unsigned char)*p))
      break;
    if (ndeps + 1 > cap_deps) {
      cap_deps = cap_deps ? cap_deps * 2 : 4096;
      deps = realloc(deps, cap_deps * sizeof(int));
    }
    deps[ndeps++] = (int)strtoul(p, &p, 10);
  }
  nchunks++;
  ck_dep[nchunks] = ndeps;
}

// 番地 a を含むかたまりと、それが使うかたまりに印を付ける
static void use_chunk_at(i64 a) {
  int lo_i = 0, hi_i = nchunks - 1, k = -1;
  while (lo_i <= hi_i) {
    int m = (lo_i + hi_i) / 2;
    if (a < ck_start[m])
      hi_i = m - 1;
    else if (a >= ck_end[m])
      lo_i = m + 1;
    else {
      k = m;
      break;
    }
  }
  if (k < 0 || ck_used[k] == 1)
    return;
  int *stack = malloc((nchunks + 1) * sizeof(int)), sp = 0;
  ck_used[k] = 1;
  stack[sp++] = k;
  while (sp) {
    int c = stack[--sp];
    for (int i = ck_dep[c]; i < ck_dep[c + 1]; i++) {
      int d = deps[i];
      if (d < 0 || d >= nchunks || ck_used[d] == 1)
        continue;
      if (ck_weak[d]) {                // 弱いかたまり：0 で埋めて入れるだけ
        ck_used[d] = 2;
        continue;
      }
      ck_used[d] = 1;
      stack[sp++] = d;
    }
  }
  free(stack);
}

// 名前.SYM を読む：「@base 16 進」「@end 16 進」「@chunk …」と「名前 16 進」の行（; で始まる行は飛ばす）
static int load_lib_syms(void) {
  char path[64];
  snprintf(path, sizeof(path), "%s.SYM", lib_name);
  FILE *fp = fopen(path, "r");
  if (!fp) {
    fprintf(stderr, "%s: cannot open\n", path);
    return 0;
  }
  while (fgets(line, sizeof(line), fp)) {
    char *p = line, *name = line;
    if (*p == ';' || *p == '\n' || *p == '\r' || !*p)
      continue;
    while (*p && *p != ' ')
      p++;
    if (!*p)
      continue;
    *p++ = 0;
    if (!strcmp(name, "@chunk")) {
      add_chunk(p);
      continue;
    }
    i64 v = (i64)strtoul(p, 0, 16);
    if (!strcmp(name, "@base"))
      lib_base = v;
    else if (!strcmp(name, "@end"))
      lib_end = v;
    else {
      define(name, v);
      lookup_sym(name)->lib = 1;
    }
  }
  fclose(fp);
  if (lib_base < 0 || lib_end < lib_base) {
    fprintf(stderr, "%s: no @base / @end\n", path);
    return 0;
  }
  return 1;
}

// 名前.BIN をそのまま fp へ写す（lib_end − lib_base バイトのはず）
static int copy_lib_bin(FILE *fp) {
  char path[64];
  snprintf(path, sizeof(path), "%s.BIN", lib_name);
  FILE *in = fopen(path, "rb");
  if (!in) {
    fprintf(stderr, "%s: cannot open\n", path);
    return 0;
  }
  i64 n = 0;
  int k;
  while ((k = fread(line, 1, sizeof(line), in)) > 0) {
    fwrite(line, 1, k, fp);
    n += k;
  }
  fclose(in);
  if (n != lib_end - lib_base) {
    fprintf(stderr, "%s: wrong size\n", path);
    return 0;
  }
  return 1;
}

// 区切りのある .EXE の本体：ライブラリのうち使うかたまり（続いているものはまとめる）と、プログラムを
// 「番地（4 バイト）・長さ（4 バイト）・中身」の並びで書く。lowest に いちばん小さい番地。本体の大きさを返す（失敗なら −1）
static void put_le32(FILE *fp, unsigned v);

static i64 write_segments(FILE *fp, i64 *lowest) {
  unsigned char *lib = 0;
  if (fp) {
    char path[64];
    snprintf(path, sizeof(path), "%s.BIN", lib_name);
    FILE *in = fopen(path, "rb");
    lib = malloc(lib_end - lib_base + 1);
    if (!in || !lib || fread(lib, 1, lib_end - lib_base, in) != (size_t)(lib_end - lib_base)) {
      fprintf(stderr, "%s: cannot read\n", path);
      if (in)
        fclose(in);
      return -1;
    }
    fclose(in);
  }
  i64 size = 0;
  *lowest = lo;
  for (int i = 0; i < nchunks;) {
    if (!ck_used[i] || ck_end[i] <= ck_start[i]) {
      i++;
      continue;
    }
    int first = i;
    i64 a = ck_start[i], b = ck_end[i];
    for (i++; i < nchunks && (ck_used[i] || ck_end[i] <= ck_start[i]) && ck_start[i] == b; i++)
      b = ck_end[i];
    if (a < lib_base || b > lib_end) {
      fprintf(stderr, "%s.SYM: bad @chunk\n", lib_name);
      return -1;
    }
    if (a < *lowest)
      *lowest = a;
    size += 8 + (b - a);
    if (fp) {
      put_le32(fp, (unsigned)a);
      put_le32(fp, (unsigned)(b - a));
      for (int j = first; j < i; j++) {    // 0 で埋めるかたまりは 0 を
        if (ck_used[j] == 2)
          memset(lib + (ck_start[j] - lib_base), 0, ck_end[j] - ck_start[j]);
      }
      fwrite(lib + (a - lib_base), 1, b - a, fp);
    }
  }
  size += 8 + (hi - lo);
  if (fp) {
    put_le32(fp, (unsigned)lo);
    put_le32(fp, (unsigned)(hi - lo));
    fwrite(image, 1, hi - lo, fp);
  }
  free(lib);
  return size;
}

// ライブラリ・すき間（0）・プログラムを書く
static int write_image(FILE *fp) {
  if (lib_name) {
    if (!copy_lib_bin(fp))
      return 0;
    for (i64 a = lib_end; a < lo; a++)
      fputc(0, fp);
  }
  return fwrite(image, 1, hi - lo, fp) == (size_t)(hi - lo);
}

static void put_le32(FILE *fp, unsigned v) {
  for (int i = 0; i < 4; i++) {
    fputc(v & 0xff, fp);
    v >>= 8;
  }
}

// 途中経過：読んだファイル・行・ラベルの数と、かかった時間
static clock_t t_start;
static void report_read(void) {
  int nlabels = 0;
  for (int i = 0; i < cap_syms; i++)
    if (syms[i].name && !syms[i].lib)
      nlabels++;
  long ds = (long)((clock() - t_start) / (CLOCKS_PER_SEC / 10));   // 0.1 秒単位
  printf("  read     %d file%s, %d lines, %d labels  (%ld.%ld s)\n", nfiles, nfiles == 1 ? "" : "s", nlines, nlabels,
         ds / 10, ds % 10);
}

int main(int argc, char **argv) {
  char *out_exe = 0, *out_bin = 0;
  t_start = clock();
  int base_set = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc)
      out_exe = argv[++i];
    else if (!strcmp(argv[i], "-bin") && i + 1 < argc)
      out_bin = argv[++i];
    else if (!strcmp(argv[i], "-b") && i + 1 < argc) {
      base = (i64)strtoul(argv[++i], 0, 0);
      base_set = 1;
    } else if (!strcmp(argv[i], "-lib") && i + 1 < argc)
      lib_name = argv[++i];
    else if (argv[i][0] == '-') {
      fprintf(stderr, "unknown option: %s\n", argv[i]);
      return 2;
    } else if (nfiles < MAX_FILES)
      files[nfiles++] = argv[i];
  }
  if (!nfiles || (!out_exe && !out_bin)) {
    fprintf(stderr, "usage: AS [-o OUT.EXE] [-bin OUT.BIN] [-b ADDR] [-lib NAME] FILE.S ...\n");
    return 2;
  }
  if (lib_name) {
    if (!load_lib_syms())
      return 1;
    if (!base_set)
      base = lib_end;
    if (base < lib_end) {
      fprintf(stderr, "-b must be after the library (%x)\n", (unsigned)lib_end);
      return 1;
    }
  }

  run_pass(1);
  if (nerrors)
    return 1;
  if (lo < 0) {
    fprintf(stderr, "nothing to output\n");
    return 1;
  }
  image = calloc(1, hi - lo);
  if (!image) {
    fprintf(stderr, "out of memory (%d bytes)\n", (int)(hi - lo));
    return 1;
  }
  run_pass(2);
  if (nerrors)
    return 1;
  report_read();

  if (out_bin) {
    FILE *fp = fopen(out_bin, "wb");
    if (!fp || !write_image(fp) || fclose(fp)) {
      fprintf(stderr, "%s: cannot write\n", out_bin);
      return 1;
    }
  }
  if (out_exe) {
    Sym *st = lookup_sym("start");
    FILE *fp = fopen(out_exe, "wb");
    if (!fp) {
      fprintf(stderr, "%s: cannot write\n", out_exe);
      return 1;
    }
    fputc('M', fp);
    fputc('Z', fp);
    if (lib_name && nchunks) {
      // 区切りのある .EXE（ヘッダの大きさの欄が 0x8010）：プログラムが使うライブラリのかたまりに印を付けてから
      ck_used = calloc(nchunks + 1, 1);
      for (int i = 0; i < cap_syms; i++)
        if (syms[i].name && syms[i].lib && syms[i].used)
          use_chunk_at(syms[i].value);
      i64 lowest, size = write_segments(0, &lowest);
      int nused = 0;
      long lib_bytes = 0;
      for (int i = 0; i < nchunks; i++)
        if (ck_used[i]) {
          nused++;
          lib_bytes += (long)(ck_end[i] - ck_start[i]);
        }
      printf("  library %d of %d parts of %s, %ld bytes\n", nused, nchunks, lib_name, lib_bytes);
      fputc(0x10, fp);
      fputc(0x80, fp);
      put_le32(fp, (unsigned)lowest);
      put_le32(fp, (unsigned)(st ? st->value : lo));
      put_le32(fp, (unsigned)size);
      if (size < 0 || write_segments(fp, &lowest) < 0 || fclose(fp)) {
        fprintf(stderr, "%s: cannot write\n", out_exe);
        return 1;
      }
      printf("%s: %d bytes\n", out_exe, (int)(size + 16));
      return 0;
    }
    fputc(16, fp);
    fputc(0, fp);
    i64 start = lib_name ? lib_base : lo;
    put_le32(fp, (unsigned)start);
    put_le32(fp, (unsigned)(st ? st->value : lo));
    put_le32(fp, (unsigned)(hi - start));
    if (!write_image(fp) || fclose(fp)) {
      fprintf(stderr, "%s: cannot write\n", out_exe);
      return 1;
    }
    printf("%s: %d bytes\n", out_exe, (int)(hi - start + 16));
  }
  return 0;
}
