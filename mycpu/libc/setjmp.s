; setjmp(r16 = jmp_buf)：r24〜r31・SP・LR を覚えて 0 を返す
_setjmp:
        STORE32_32 r24, r16, 0
        STORE32_32 r25, r16, 4
        STORE32_32 r26, r16, 8
        STORE32_32 r27, r16, 12
        STORE32_32 r28, r16, 16
        STORE32_32 r29, r16, 20
        STORE32_32 r30, r16, 24
        STORE32_32 r31, r16, 28
        STORE32_32 sp, r16, 32
        STORE32_32 lr, r16, 36
        ADDI32 r16, r0, 0
        RET32

; longjmp(r16 = jmp_buf, r17 = 値)：覚えた状態に戻り、setjmp が「値」（0 なら 1）を返したことにする
_longjmp:
        LOAD32_32 r24, r16, 0
        LOAD32_32 r25, r16, 4
        LOAD32_32 r26, r16, 8
        LOAD32_32 r27, r16, 12
        LOAD32_32 r28, r16, 16
        LOAD32_32 r29, r16, 20
        LOAD32_32 r30, r16, 24
        LOAD32_32 r31, r16, 28
        LOAD32_32 sp, r16, 32
        LOAD32_32 lr, r16, 36
        ADDI32 r18, r0, 1
        CMPEQI32 p1, r17, 0
        SEL32 r16, r18, r17, p1
        RET32
