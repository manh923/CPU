// clock() の一周（タイマーは 32bit・1µs で約 71 分）をまたいでも、ゲームの「1 秒に 60 回」の待ち方が止まらないか。
// タイマーを一周の少し前（と、前の clock() が 0 に戻っていた 2^31 の少し前）に合わせて、60 分の 1 秒を 12 回待つ。
// test/run.js が test/cctest.js の runC で動かす（タイマーに書くので MyDOS の上では動かさない）
#include <stdio.h>
#include <time.h>

#define TIMER_COUNT ((volatile unsigned *)0x00010010)

static long since(unsigned long t) { return (long)((unsigned long)clock() - t); }

static int frames_across(unsigned start) {
  *TIMER_COUNT = start;
  unsigned long t0 = clock(), next = t0;
  for (int i = 0; i < 12; i++) {
    next += CLOCKS_PER_SEC / 60;
    while (since(next) < 0)
      ;
    if (since(next) > CLOCKS_PER_SEC)
      next = clock();
  }
  return (int)since(t0);              // 12 フレーム ≒ 0.2 秒
}

int main(void) {
  int ng = 0;
  unsigned starts[] = {0xFFFFFFFFu - 100000, 0x7FFFFFFFu - 100000};
  for (int i = 0; i < 2; i++) {
    int us = frames_across(starts[i]);
    printf("start %08x: %d us\n", starts[i], us);
    if (us < 199000 || us > 260000)
      ng++;
  }
  printf("clocktest: %d 件 NG\n", ng);
  return ng != 0;
}
