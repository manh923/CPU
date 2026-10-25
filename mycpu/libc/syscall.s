; int __syscall(int n, int a, int b, int c)：SYSCALL n を呼ぶ（引数は r16〜r18、戻り値は r16）
___syscall:
        ADDR32 r23, r16, r0
        ADDR32 r16, r17, r0
        ADDR32 r17, r18, r0
        ADDR32 r18, r19, r0
        SYSCALL
        RET32
