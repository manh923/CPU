// 画面とキー：BIOS の SYSCALL（5 = cls、11 = gotoxy、12 = getxy、9 = setattr、10 = kbhit、3 = getc）
#include <conio.h>
#include <time.h>
#include <mycpu.h>

void clrscr(void) { __syscall(SYS_CLS, 0, 0, 0); }
void gotoxy(int x, int y) { __syscall(SYS_GOTOXY, x, y, 0); }
int wherex(void) { return __syscall(SYS_GETXY, 0, 0, 0) & 0xffff; }
int wherey(void) { return __syscall(SYS_GETXY, 0, 0, 0) >> 16; }
int textattr(int attr) { return __syscall(SYS_SETATTR, attr, 0, 0); }
void putch(int c) { __syscall(SYS_PUTC, c & 0xff, 0, 0); }
void cputs(const char *s) { __syscall(SYS_PUTS, (int)s, 0, 0); }
int kbhit(void) { return __syscall(SYS_KBHIT, 0, 0, 0); }

static int rawgetc(void) { return __syscall(SYS_GETC, 0, 0, 0) & 0xff; }

// 次のキーが 30ms 以内に来るか（ESC 1 つと、ESC で始まる並びを見分ける）
static int soon(void) {
  clock_t t0 = clock();
  while (clock() - t0 < 30000)
    if (kbhit())
      return 1;
  return 0;
}

int getch(void) {
  int c = rawgetc();
  if (c != 27 || !soon())
    return c;
  int c2 = rawgetc();
  if (c2 == 'O') {                       // ESC O P〜S = F1〜F4
    int c3 = rawgetc();
    if (c3 >= 'P' && c3 <= 'S')
      return KEY_F1 + (c3 - 'P');
    return KEY_ESC;
  }
  if (c2 != '[')
    return c2;                           // ESC と別の文字：ESC は捨てる
  int c3 = rawgetc();
  switch (c3) {
  case 'A': return KEY_UP;
  case 'B': return KEY_DOWN;
  case 'C': return KEY_RIGHT;
  case 'D': return KEY_LEFT;
  case 'H': return KEY_HOME;
  case 'F': return KEY_END;
  }
  if (c3 >= '0' && c3 <= '9') {          // ESC [ 数 ~
    int n = c3 - '0';
    int c4;
    while ((c4 = rawgetc()) >= '0' && c4 <= '9')
      n = n * 10 + (c4 - '0');
    switch (n) {
    case 1: case 7: return KEY_HOME;
    case 4: case 8: return KEY_END;
    case 2: return KEY_INS;
    case 3: return KEY_DEL;
    case 5: return KEY_PGUP;
    case 6: return KEY_PGDN;
    case 11: case 12: case 13: case 14: return KEY_F1 + (n - 11);
    }
  }
  return KEY_ESC;
}
