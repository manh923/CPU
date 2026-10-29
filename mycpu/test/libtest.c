// C ライブラリ（libc/）のテスト。test/run.js が MyDOS の上で動かす（ファイルを使うので SD カードが要る）
// 項目ごとに名前と ok / NG を出し、最後に "libtest: N NG" を出す
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <inttypes.h>
#include <setjmp.h>
#include <assert.h>
#include <time.h>

static int ng;

static void check(const char *name, int ok) {
  printf("%-28s %s\n", name, ok ? "ok" : "NG");
  if (!ok)
    ng++;
}

static int cmp_int(const void *a, const void *b) {
  return *(const int *)a - *(const int *)b;
}

static jmp_buf jb;
static int depth;

static void deep(int n) {
  depth = n;
  if (n == 50)
    longjmp(jb, 42);
  deep(n + 1);
}

int main(void) {
  char buf[200];

  // ---- 文字列・書式 ----
  sprintf(buf, "[%5d|%-5d|%05d|%x|%X|%#x|%o|%c|%s|%.3s|%%]", 42, 42, 42, 255, 255, 255, 8, 'A', "str", "abcdef");
  check("sprintf", !strcmp(buf, "[   42|42   |00042|ff|FF|0xff|10|A|str|abc|%]"));
  snprintf(buf, sizeof(buf), "%lld %llu %llx %" PRId64, -1234567890123LL, 18446744073709551615ULL, 0x123456789abcdefULL,
           (int64_t)INT64_MIN);
  check("printf long long", !strcmp(buf, "-1234567890123 18446744073709551615 123456789abcdef -9223372036854775808"));
  check("snprintf truncate", snprintf(buf, 5, "%s", "abcdefgh") == 8 && !strcmp(buf, "abcd"));
  check("strtol", strtol("  -123xyz", 0, 10) == -123 && strtol("0x1F", 0, 0) == 31 && strtoul("777", 0, 8) == 511);
  check("atoi", atoi("2026") == 2026);
  strcpy(buf, "a,b,,c");
  char *t1 = strtok(buf, ","), *t2 = strtok(0, ","), *t3 = strtok(0, ","), *t4 = strtok(0, ",");
  check("strtok", !strcmp(t1, "a") && !strcmp(t2, "b") && !strcmp(t3, "c") && !t4);
  check("strstr strchr", strstr("hello world", "wor") && *strrchr("a/b/c", '/') == '/' && !strchr("abc", 'z'));
  check("ctype", isalpha('a') && !isalpha('1') && isdigit('7') && toupper('q') == 'Q' && isspace('\t'));
  check("limits", INT_MAX == 2147483647 && LLONG_MAX == 9223372036854775807LL && sizeof(long) == 4 && sizeof(void *) == 4);

  // ---- 64bit の計算 ----
  long long a = 1000000007LL * 1000000009LL;
  check("long long *", a == 1000000016000000063LL);
  check("long long / %", a / 1000000009LL == 1000000007LL && a % 1000 == 63 && -a / 7 == -142857145142857151LL);
  unsigned long long u = 1ULL << 63;
  check("long long shift", (u >> 63) == 1 && (u >> 1) == 0x4000000000000000ULL && ((long long)u >> 62) == -2);
  check("long long compare", -1LL < 1LL && 1ULL < u && (long long)u < 0);

  // ---- メモリ ----
  int *v = malloc(100 * sizeof(int));
  for (int i = 0; i < 100; i++)
    v[i] = (i * 37) % 101;
  qsort(v, 100, sizeof(int), cmp_int);
  int sorted = 1;
  for (int i = 1; i < 100; i++)
    if (v[i - 1] > v[i])
      sorted = 0;
  v = realloc(v, 1000 * sizeof(int));
  check("malloc qsort realloc", sorted && v && v[99] == 100);
  free(v);
  void *ps[50];
  for (int i = 0; i < 50; i++)
    ps[i] = malloc(i * 13 + 1);
  for (int i = 0; i < 50; i += 2)
    free(ps[i]);
  void *again = malloc(14);
  check("malloc reuse", again == ps[2] || again == ps[0] || again != 0);

  // ---- setjmp ----
  int r = setjmp(jb);
  if (r == 0)
    deep(0);
  check("setjmp longjmp", r == 42 && depth == 50);

  // ---- ファイル ----
  FILE *fp = fopen("LIBTEST.TXT", "w");
  check("fopen w", fp != 0);
  for (int i = 1; i <= 300; i++)
    fprintf(fp, "line %d\n", i);
  check("fclose", fclose(fp) == 0);

  fp = fopen("libtest.txt", "r");
  int lines = 0, last = 0;
  while (fgets(buf, sizeof(buf), fp)) {
    lines++;
    last = atoi(buf + 5);
  }
  check("fgets 300 lines", lines == 300 && last == 300 && feof(fp));
  check("fseek ftell", fseek(fp, 0, SEEK_END) == 0 && ftell(fp) == 2592 &&
        fseek(fp, -9, SEEK_END) == 0 && fgets(buf, sizeof(buf), fp) && !strcmp(buf, "line 300\n"));
  rewind(fp);
  check("rewind ungetc", fgetc(fp) == 'l' && ungetc('X', fp) == 'X' && fgetc(fp) == 'X' && fgetc(fp) == 'i' && ftell(fp) == 2);
  fseek(fp, 7, SEEK_SET);
  check("fread", fread(buf, 1, 7, fp) == 7 && !memcmp(buf, "line 2\n", 7));
  fclose(fp);

  fp = fopen("LIBTEST.TXT", "a");
  fputs("appended\n", fp);
  fclose(fp);
  fp = fopen("LIBTEST.TXT", "r");
  fseek(fp, -9, SEEK_END);
  check("fopen a", fgets(buf, sizeof(buf), fp) && !strcmp(buf, "appended\n"));
  fclose(fp);

  // 大きなファイル：SDRAM のバッファ 40KB を書いて読む
  unsigned char *big = malloc(40000);
  for (int i = 0; i < 40000; i++)
    big[i] = i * 7 + (i >> 8);
  fp = fopen("BIG.BIN", "wb");
  check("fwrite 40KB", fwrite(big, 1, 40000, fp) == 40000 && fclose(fp) == 0);
  memset(big, 0, 40000);
  fp = fopen("BIG.BIN", "rb");
  size_t got = fread(big, 1, 40000, fp);
  int same = 1;
  for (int i = 0; i < 40000; i++)
    if (big[i] != (unsigned char)(i * 7 + (i >> 8)))
      same = 0;
  check("fread 40KB", got == 40000 && same && fread(big, 1, 10, fp) == 0 && feof(fp));
  fclose(fp);

  check("rename", rename("BIG.BIN", "BIG2.BIN") == 0 && fopen("BIG.BIN", "r") == 0 && errno == ENOENT);
  check("remove", remove("BIG2.BIN") == 0 && remove("BIG2.BIN") == -1 && errno == ENOENT);
  check("remove LIBTEST.TXT", remove("LIBTEST.TXT") == 0);
  check("fopen bad name", fopen("A*B.TXT", "r") == 0 && errno == EINVAL);
  check("strerror", !strcmp(strerror(ENOENT), "File not found"));

  // ---- scanf ----
  {
    int a = 0, b = 0, n = 0;
    unsigned u = 0;
    long long ll = 0;
    char w1[20] = "", w2[20] = "", cs[4] = "";
    double d = 0;
    float f = 0;
    check("sscanf %d %x %u", sscanf("-42 1f 7", "%d %x %u", &a, &b, &u) == 3 && a == -42 && b == 31 && u == 7);
    check("sscanf %i %lld %n", sscanf("0x10 -123456789012", "%i %lld%n", &a, &ll, &n) == 2 && a == 16 &&
                                   ll == -123456789012LL && n == 18);
    check("sscanf %s %[ %c", sscanf("ab,cd xyz", "%[^,],%s %2c", w1, w2, cs) == 3 && !strcmp(w1, "ab") &&
                                 !strcmp(w2, "cd") && cs[0] == 'x' && cs[1] == 'y');
    check("sscanf %lf %f", sscanf("3.25 -1e-3", "%lf %f", &d, &f) == 2 && d == 3.25 && f == -1e-3f);
    check("sscanf EOF / partial", sscanf("", "%d", &a) == EOF && sscanf("12 x", "%d %d", &a, &b) == 1 && a == 12);
    fp = fopen("SCAN.TXT", "w");
    fprintf(fp, "10 20\nname 3.5\n");
    fclose(fp);
    fp = fopen("SCAN.TXT", "r");
    check("fscanf", fscanf(fp, "%d %d %s %lf", &a, &b, w1, &d) == 4 && a == 10 && b == 20 && !strcmp(w1, "name") &&
                        d == 3.5 && fscanf(fp, "%d", &a) == EOF);
    fclose(fp);
    remove("SCAN.TXT");
  }

  // ---- 時間 ----
  time_t now = time(0);
  struct tm *tm = localtime(&now);
  strftime(buf, sizeof(buf), "%Y-%m-%d", tm);
  check("time", !strcmp(buf, "2026-01-01") && clock() >= 0);

  assert(ng == 0);
  printf("libtest: %d NG\n", ng);
  return 0;
}
