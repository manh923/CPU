// libc/softfloat.s（double の計算のアセンブリ版）のテスト：この CPU（シミュレータ）で動かし、libc/softfloat.c の
// C 版と結果をビット単位で比べる。C 版は PC の FPU と同じになることを test/floattest.c で確かめてあるので、
// アセンブリ版も PC と同じになる。test/run.js が test/cctest.js の runC で動かす
#include <stdio.h>

// C 版は名前を変えて入れる（libc の中のアセンブリ版とぶつからないように）
#define SOFTFLOAT_REF
#define __adddf3 ref_adddf3
#define __subdf3 ref_subdf3
#define __muldf3 ref_muldf3
#define __divdf3 ref_divdf3
#define __mycpu_dcmp ref_dcmp
#define __floatdidf ref_floatdidf
#define __floatundidf ref_floatundidf
#define __floatsidf ref_floatsidf
#define __floatunsidf ref_floatunsidf
#define __fixdfdi ref_fixdfdi
#define __fixunsdfdi ref_fixunsdfdi
#define __fixdfsi ref_fixdfsi
#define __fixunsdfsi ref_fixunsdfsi
#define __extendsfdf2 ref_extendsfdf2
#define __truncdfsf2 ref_truncdfsf2
#define __addsf3 ref_addsf3
#define __subsf3 ref_subsf3
#define __mulsf3 ref_mulsf3
#define __divsf3 ref_divsf3
#define __mycpu_fcmp ref_fcmp
#define __floatsisf ref_floatsisf
#define __floatunsisf ref_floatunsisf
#define __fixsfsi ref_fixsfsi
#define __fixunssfsi ref_fixunssfsi
#define __fixsfdi ref_fixsfdi
#define __fixunssfdi ref_fixunssfdi
#define __floatdisf ref_floatdisf
#define __floatundisf ref_floatundisf
#include "../libc/softfloat.c"
#undef __adddf3
#undef __subdf3
#undef __muldf3
#undef __divdf3
#undef __mycpu_dcmp
#undef __floatsidf
#undef __floatunsidf
#undef __fixdfsi
#undef __fixunsdfsi
#undef __extendsfdf2
#undef __truncdfsf2
#undef __addsf3
#undef __subsf3
#undef __mulsf3
#undef __divsf3
#undef __mycpu_fcmp
#undef __floatsisf
#undef __floatunsisf
#undef __fixsfsi
#undef __fixunssfsi

// アセンブリ版（libc）
u64 __adddf3(u64, u64);
u64 __subdf3(u64, u64);
u64 __muldf3(u64, u64);
u64 __divdf3(u64, u64);
int __mycpu_dcmp(u64, u64);
u64 __floatsidf(int);
u64 __floatunsidf(u32);
int __fixdfsi(u64);
u32 __fixunsdfsi(u64);
u64 __extendsfdf2(u32);
u32 __truncdfsf2(u64);
u32 __addsf3(u32, u32);       // C（libc/softfloat.c）だが、中でアセンブリ版を使う
u32 __subsf3(u32, u32);
u32 __mulsf3(u32, u32);
u32 __divsf3(u32, u32);
int __mycpu_fcmp(u32, u32);
u32 __floatsisf(int);
u32 __floatunsisf(u32);
int __fixsfsi(u32);
u32 __fixunssfsi(u32);

static u64 state = 88172645463325252ULL;
static u64 rnd(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

static u64 specials[] = {
  0, 0x8000000000000000ULL, 0x3FF0000000000000ULL, 0xBFF0000000000000ULL, 0x7FF0000000000000ULL, 0xFFF0000000000000ULL,
  0x7FF8000000000000ULL, 0xFFF0000000000001ULL, 1, 0x800FFFFFFFFFFFFFULL, 0x0010000000000000ULL, 0x7FEFFFFFFFFFFFFFULL,
  0x3FE0000000000000ULL, 0x4340000000000000ULL, 0x43E0000000000000ULL, 0xC3E0000000000000ULL, 0x41E0000000000000ULL,
  0xC1E0000000000000ULL, 0x41DFFFFFFFC00000ULL, 0x41EFFFFFFFE00000ULL, 0x3CB0000000000000ULL, 0x000FFFFFFFFFFFFFULL,
};
#define NSPECIAL (sizeof(specials) / sizeof(specials[0]))

// いろいろな double：特別な値、ランダムなビット列、指数を近くにしたもの、非正規化数・最大の近く、整数の近く
static u64 rand_d(void) {
  switch (rnd() % 7) {
  case 0: return specials[rnd() % NSPECIAL];
  case 1: return rnd();
  case 2: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(1023 + (int)(rnd() % 40) - 20) << 52);
  case 3: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(rnd() % 60) << 52);
  case 4: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(2046 - rnd() % 60) << 52);
  case 5: return (rnd() & 0x800FFFFFFFFFFFFFULL) | ((u64)(1023 + rnd() % 34) << 52);   // int に変換できる大きさ
  default: return ref_floatsidf((int)rnd()) ^ (rnd() & 3);
  }
}

static u32 rand_f(void) {
  switch (rnd() % 5) {
  case 0: return ref_truncdfsf2(specials[rnd() % NSPECIAL]);
  case 1: return (u32)rnd();
  case 2: return ((u32)rnd() & 0x807FFFFF) | ((u32)(127 + (int)(rnd() % 30) - 15) << 23);
  case 3: return ((u32)rnd() & 0x807FFFFF) | ((u32)(rnd() % 30) << 23);
  default: return ((u32)rnd() & 0x807FFFFF) | ((u32)(127 + rnd() % 34) << 23);
  }
}

static int ng, n;
static void report(const char *what, u64 a, u64 b, u64 got, u64 want) {
  if (ng++ < 20)
    printf("NG %s %016llx %016llx: got %016llx want %016llx\n", what, a, b, got, want);
}

static void check(u64 a, u64 b) {
  n++;
  u64 g, w;
  if ((g = __adddf3(a, b)) != (w = ref_adddf3(a, b))) report("add", a, b, g, w);
  if ((g = __subdf3(a, b)) != (w = ref_subdf3(a, b))) report("sub", a, b, g, w);
  if ((g = __muldf3(a, b)) != (w = ref_muldf3(a, b))) report("mul", a, b, g, w);
  if ((g = __divdf3(a, b)) != (w = ref_divdf3(a, b))) report("div", a, b, g, w);
  if (__mycpu_dcmp(a, b) != ref_dcmp(a, b)) report("dcmp", a, b, __mycpu_dcmp(a, b), ref_dcmp(a, b));
  if (__fixdfsi(a) != ref_fixdfsi(a)) report("fixdfsi", a, 0, __fixdfsi(a), ref_fixdfsi(a));
  if (__fixunsdfsi(a) != ref_fixunsdfsi(a)) report("fixunsdfsi", a, 0, __fixunsdfsi(a), ref_fixunsdfsi(a));
  int iv = (int)b >> (b >> 59);
  if (__floatsidf(iv) != ref_floatsidf(iv)) report("floatsidf", iv, 0, __floatsidf(iv), ref_floatsidf(iv));
  if (__floatunsidf(iv) != ref_floatunsidf(iv)) report("floatunsidf", iv, 0, __floatunsidf(iv), ref_floatunsidf(iv));
  if (__truncdfsf2(a) != ref_truncdfsf2(a)) report("truncdfsf2", a, 0, __truncdfsf2(a), ref_truncdfsf2(a));
  if (__floatsisf(iv) != ref_floatsisf(iv)) report("floatsisf", iv, 0, __floatsisf(iv), ref_floatsisf(iv));
  if (__floatunsisf(iv) != ref_floatunsisf(iv)) report("floatunsisf", iv, 0, __floatunsisf(iv), ref_floatunsisf(iv));
}

static void checkf(u32 a, u32 b) {
  u64 g, w;
  if ((g = __extendsfdf2(a)) != (w = ref_extendsfdf2(a))) report("extendsfdf2", a, 0, g, w);
  if ((g = __addsf3(a, b)) != (w = ref_addsf3(a, b))) report("addsf3", a, b, g, w);
  if ((g = __subsf3(a, b)) != (w = ref_subsf3(a, b))) report("subsf3", a, b, g, w);
  if ((g = __mulsf3(a, b)) != (w = ref_mulsf3(a, b))) report("mulsf3", a, b, g, w);
  if ((g = __divsf3(a, b)) != (w = ref_divsf3(a, b))) report("divsf3", a, b, g, w);
  if (__mycpu_fcmp(a, b) != ref_fcmp(a, b)) report("fcmp", a, b, __mycpu_fcmp(a, b), ref_fcmp(a, b));
  if (__fixsfsi(a) != ref_fixsfsi(a)) report("fixsfsi", a, 0, __fixsfsi(a), ref_fixsfsi(a));
  if (__fixunssfsi(a) != ref_fixunssfsi(a)) report("fixunssfsi", a, 0, __fixunssfsi(a), ref_fixunssfsi(a));
}

int main(void) {
  for (int i = 0; i < NSPECIAL; i++)
    for (int j = 0; j < NSPECIAL; j++)
      check(specials[i], specials[j]);
  for (int i = 0; i < 20000; i++) {
    check(rand_d(), rand_d());
    checkf(rand_f(), rand_f());
  }
  printf("fasmtest: %d 組、%d 件 NG\n", n, ng);
  return ng != 0;
}
