; crt0.s — C のプログラムの入口。MyDOS から r16 = 引数の文字列で呼ばれる（ユーザーモード）
; __start（libc/start.c）に main の番地とヒープの始まり（___heap_start。リンクの最後に置かれる）を渡す。
; __start が引数を分けて main を呼び、戻ってきたら exit する。
; （libc の側から main・___heap_start を直接見ないので、libc だけ先にアセンブルしておける。AS -lib）
start:
        ADDR32 r18, r16, r0             ; 引数の文字列
        ADDI32 r16, r0, _main
        ADDI32 r17, r0, ___heap_start
        CALL32 ___start
        ADDI32 r23, r0, 0               ; 戻ってこないはずだが、念のため SYSCALL 0（終了）
        SYSCALL
