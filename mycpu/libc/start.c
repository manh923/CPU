// C のプログラムの始まり：MyDOS から受け取った引数の文字列を空白で分けて main を呼ぶ
#include <stdlib.h>

int main(int argc, char **argv);

static char args_buf[128];
static char *argv_buf[33];

int __start(char *args) {
  int argc = 0;
  argv_buf[argc++] = "PROG";          // MyDOS はプログラムの名前を渡さない

  int i = 0;
  while (args && args[i] && i < (int)sizeof(args_buf) - 1) {
    args_buf[i] = args[i];
    i++;
  }
  args_buf[i] = 0;

  char *p = args_buf;
  while (*p && argc < 32) {
    while (*p == ' ')
      *p++ = 0;
    if (!*p)
      break;
    argv_buf[argc++] = p;
    while (*p && *p != ' ')
      p++;
  }
  argv_buf[argc] = 0;

  exit(main(argc, argv_buf));
}
