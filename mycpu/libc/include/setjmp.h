#ifndef __SETJMP_H
#define __SETJMP_H

// r24〜r31・SP・LR を覚えておく（libc/setjmp.s）
typedef int jmp_buf[10];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

#endif
