; crt0.s — C のプログラムの入口。MyDOS から r16 = 引数の文字列で呼ばれる（ユーザーモード）
; __start（libc/start.c）が引数を分けて main を呼び、戻ってきたら exit する。
start:
        CALL32 ___start
        ADDI32 r23, r0, 0               ; 戻ってこないはずだが、念のため SYSCALL 0（終了）
        SYSCALL

; int __syscall(int n, int a, int b, int c)：SYSCALL n を呼ぶ（引数は r16〜r18、戻り値は r16）
___syscall:
        ADDR32 r23, r16, r0
        ADDR32 r16, r17, r0
        ADDR32 r17, r18, r0
        ADDR32 r18, r19, r0
        SYSCALL
        RET32
