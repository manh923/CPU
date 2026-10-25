#ifndef __CONIO_H
#define __CONIO_H

// 画面とキー（libc/conio.c）。画面は 160 桁 × 45 行（UART の端末にも同じものが出る）
#define SCREEN_COLS 160
#define SCREEN_ROWS 45

// getch() が返す特別なキー（端末の ESC [ … の並びをまとめたもの）
#define KEY_ESC    27
#define KEY_UP     0x100
#define KEY_DOWN   0x101
#define KEY_LEFT   0x102
#define KEY_RIGHT  0x103
#define KEY_HOME   0x104
#define KEY_END    0x105
#define KEY_PGUP   0x106
#define KEY_PGDN   0x107
#define KEY_INS    0x108
#define KEY_DEL    0x109
#define KEY_F1     0x110
#define KEY_F2     0x111
#define KEY_F3     0x112
#define KEY_F4     0x113

void clrscr(void);
void gotoxy(int x, int y);       // 0 から数える
int wherex(void);
int wherey(void);
int textattr(int attr);          // 色（上位 4bit が背景、下位 4bit が文字）。前の色を返す
void putch(int c);
void cputs(const char *s);
int getch(void);                 // 1 つのキー（画面には出さない）
int kbhit(void);

#endif
