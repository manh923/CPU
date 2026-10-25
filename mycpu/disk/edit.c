// EDIT.EXE — 全画面のテキストエディタ。80 桁 × 24 行（UART の端末でもそのまま使える）
//   EDIT 名前        ファイルがなければ新しく作る
// 矢印・Home・End・PgUp・PgDn で動く。Enter・Backspace・Delete・Tab。Ctrl-S で保存、Ctrl-X で終わり
// 保存は CRLF で。読むときはタブを空白にする（4 桁ごと）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <conio.h>

#define W 80                    // 画面の幅
#define H 23                    // 本文の行数（24 行目は状態の行）
#define TAB 4

typedef struct {
  char *s;
  int len, cap;
} Line;

static Line *lines;
static int nlines, cap_lines;
static int cx, cy;              // カーソル：何文字目・何行目
static int top, left;           // 画面の左上に見えている行・文字
static int dirty;               // 保存していない変更がある
static char *fname;
static char msg[W + 1];
static char shown[H + 1][W + 1];   // 画面に出してある中身（変わった行だけ書き直す）

// ---- 行 ----
static void reserve(Line *l, int n) {
  if (n + 1 <= l->cap)
    return;
  int cap = l->cap ? l->cap : 16;
  while (cap < n + 1)
    cap *= 2;
  l->s = realloc(l->s, cap);
  l->cap = cap;
}

static void insert_line(int at, const char *s, int len) {
  if (nlines == cap_lines) {
    cap_lines = cap_lines ? cap_lines * 2 : 64;
    lines = realloc(lines, cap_lines * sizeof(Line));
  }
  memmove(&lines[at + 1], &lines[at], (nlines - at) * sizeof(Line));
  Line *l = &lines[at];
  l->s = 0;
  l->len = l->cap = 0;
  reserve(l, len);
  memcpy(l->s, s, len);
  l->len = len;
  l->s[len] = 0;
  nlines++;
}

static void delete_line(int at) {
  free(lines[at].s);
  memmove(&lines[at], &lines[at + 1], (nlines - at - 1) * sizeof(Line));
  nlines--;
}

static void insert_char(int c) {
  Line *l = &lines[cy];
  reserve(l, l->len + 1);
  memmove(l->s + cx + 1, l->s + cx, l->len - cx + 1);
  l->s[cx++] = c;
  l->len++;
  dirty = 1;
}

static void enter(void) {
  Line *l = &lines[cy];
  insert_line(cy + 1, l->s + cx, l->len - cx);
  l = &lines[cy];                       // insert_line で lines が動くことがある
  l->len = cx;
  l->s[cx] = 0;
  cy++;
  cx = 0;
  dirty = 1;
}

// カーソルの前の 1 文字を消す（行頭なら前の行とつなぐ）
static void backspace(void) {
  if (cx > 0) {
    Line *l = &lines[cy];
    memmove(l->s + cx - 1, l->s + cx, l->len - cx + 1);
    l->len--;
    cx--;
    dirty = 1;
  } else if (cy > 0) {
    Line *p = &lines[cy - 1], *l = &lines[cy];
    cx = p->len;
    reserve(p, p->len + l->len);
    memcpy(p->s + p->len, l->s, l->len + 1);
    p->len += l->len;
    delete_line(cy);
    cy--;
    dirty = 1;
  }
}

static void del(void) {
  if (cx < lines[cy].len) {
    cx++;
    backspace();
  } else if (cy + 1 < nlines) {
    cy++;
    cx = 0;
    backspace();
  }
}

// ---- ファイル ----
static void load(void) {
  FILE *fp = fopen(fname, "r");
  char buf[1024];
  int len = 0;
  if (fp) {
    int c;
    while ((c = fgetc(fp)) != EOF) {
      if (c == '\r')
        continue;
      if (c == '\n') {
        insert_line(nlines, buf, len);
        len = 0;
        continue;
      }
      if (c == '\t') {
        do
          buf[len++] = ' ';
        while (len % TAB && len < (int)sizeof(buf) - 1);
        continue;
      }
      if (len < (int)sizeof(buf) - 1)
        buf[len++] = c;
    }
    fclose(fp);
    snprintf(msg, sizeof(msg), "%s: %d lines", fname, nlines + (len > 0));
  } else {
    snprintf(msg, sizeof(msg), "%s: new file", fname);
  }
  if (len > 0 || nlines == 0)
    insert_line(nlines, buf, len);
}

static int save(void) {
  FILE *fp = fopen(fname, "w");
  if (!fp) {
    snprintf(msg, sizeof(msg), "Cannot save %s", fname);
    return 0;
  }
  // 最後の行が空なら、そこは書かない（ファイルの終わりの改行になる）
  int n = nlines;
  if (n > 1 && lines[n - 1].len == 0)
    n--;
  for (int i = 0; i < n; i++) {
    fwrite(lines[i].s, 1, lines[i].len, fp);
    fputs("\r\n", fp);
  }
  if (fclose(fp) != 0) {
    snprintf(msg, sizeof(msg), "Write error (disk full?)");
    return 0;
  }
  dirty = 0;
  snprintf(msg, sizeof(msg), "Saved %s (%d lines)", fname, n);
  return 1;
}

// ---- 画面 ----
static void put_row(int row, const char *text) {
  if (!memcmp(shown[row], text, W))
    return;
  memcpy(shown[row], text, W);
  gotoxy(0, row);
  cputs(text);
}

static void draw(void) {
  // カーソルが見えるように左上をずらす
  if (cy < top)
    top = cy;
  if (cy >= top + H)
    top = cy - H + 1;
  if (cx < left)
    left = cx;
  if (cx >= left + W)
    left = cx - W + 1;

  char row[W + 1];
  for (int y = 0; y < H; y++) {
    memset(row, ' ', W);
    row[W] = 0;
    int i = top + y;
    if (i < nlines) {
      Line *l = &lines[i];
      for (int x = 0; x < W && left + x < l->len; x++)
        row[x] = l->s[left + x];
    } else {
      row[0] = '~';
    }
    put_row(y, row);
  }

  // 状態の行：名前・変更の印・位置・メッセージ
  char st[W + 1];
  memset(st, ' ', W);
  st[W] = 0;
  char left_part[W + 1], right_part[40];
  snprintf(left_part, sizeof(left_part), " %s%s  %s", fname, dirty ? " *" : "", msg);
  snprintf(right_part, sizeof(right_part), "Ln %d, Col %d  ^S Save ^X Exit ", cy + 1, cx + 1);
  int ll = strlen(left_part), rl = strlen(right_part);
  memcpy(st, left_part, ll < W ? ll : W);
  if (rl < W)
    memcpy(st + W - rl, right_part, rl);
  put_row(H, st);
  gotoxy(cx - left, cy - top);
}

// Ctrl-X：保存していなければ聞く。戻り値 1 で終わる
static int ask_quit(void) {
  if (!dirty)
    return 1;
  snprintf(msg, sizeof(msg), "Save changes? (Y/N, Esc = cancel)");
  draw();
  for (;;) {
    int c = getch();
    if (c == 'y' || c == 'Y')
      return save();
    if (c == 'n' || c == 'N')
      return 1;
    if (c == KEY_ESC) {
      msg[0] = 0;
      return 0;
    }
  }
}

int main(int argc, char **argv) {
  if (argc < 2) {
    printf("Usage: EDIT filename\n");
    return 1;
  }
  fname = argv[1];
  for (char *p = fname; *p; p++)
    if (*p >= 'a' && *p <= 'z')
      *p -= 32;
  load();

  clrscr();
  memset(shown, 0, sizeof(shown));
  for (;;) {
    draw();
    int c = getch();
    if (c != 19 && c != 24)
      msg[0] = 0;
    switch (c) {
    case KEY_UP: if (cy > 0) cy--; break;
    case KEY_DOWN: if (cy + 1 < nlines) cy++; break;
    case KEY_LEFT:
      if (cx > 0) cx--;
      else if (cy > 0) { cy--; cx = lines[cy].len; }
      break;
    case KEY_RIGHT:
      if (cx < lines[cy].len) cx++;
      else if (cy + 1 < nlines) { cy++; cx = 0; }
      break;
    case KEY_HOME: cx = 0; break;
    case KEY_END: cx = lines[cy].len; break;
    case KEY_PGUP: cy = cy > H ? cy - H : 0; break;
    case KEY_PGDN: cy = cy + H < nlines ? cy + H : nlines - 1; break;
    case KEY_DEL: del(); break;
    case 8:
    case 127: backspace(); break;
    case 13:
    case 10: enter(); break;
    case 9:
      do
        insert_char(' ');
      while (cx % TAB);
      break;
    case 19: save(); break;                 // Ctrl-S
    case 24:                                // Ctrl-X
      if (ask_quit()) {
        clrscr();
        return 0;
      }
      break;
    default:
      if (c >= 32 && c < 127)
        insert_char(c);
    }
    if (cx > lines[cy].len)
      cx = lines[cy].len;
  }
}
