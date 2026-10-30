; double の計算をアセンブリで（libc/softfloat.c の C 版より何倍も速い。C 版は 64bit の値を 32bit 2 つで扱うので遅い）
;   足す・引く・掛ける・割る・比べる・int との変換。結果は C 版（PC の FPU とビット単位で同じ）と同じ：
;   丸めは最近接偶数、無限大・NaN（いつも 0x7FF8000000000000）・非正規化数も。test/fasmtest.c が C 版と比べる
; 呼び出し規約：double の引数はスタック（a が [sp+0]〜[sp+7]、b が [sp+8]〜[sp+15]。下位の 4 バイトが先）、
;   int の引数は r16。double の戻り値は r16（下位）・r17（上位）。
; 足す・掛ける・割るは r24〜r27 も使うので、入口でスタックに退避し、___mycpu_dret で戻す
; 仮数は 2 語（上位・下位）で持ち、丸めのために 3 bit 左へずらしておく（先頭の 1 が bit 55）

; @fn ___mycpu_dret
; 足す・掛ける・割るの終わり：r24〜r27 を戻して返る（戻り値は r16・r17）
___mycpu_dret:
        LOAD32_32 r24, sp, 0
        LOAD32_32 r25, sp, 4
        LOAD32_32 r26, sp, 8
        LOAD32_32 r27, sp, 12
        ADDI32 sp, sp, 16
        RET32

; @fn ___mycpu_dpack
; 符号 r25（0 か 0x80000000）、指数 r22、仮数 r20:r16（0 以外、先頭の 1 は bit 56 まで）の
; 値 = 仮数 × 2^(指数 − 1023 − 55) を double に丸めて r16・r17 に入れ、___mycpu_dret へ
___mycpu_dpack:
        ; 先頭の 1 を bit 55 に：左へ n = clz − 8（n = −1 なら右へ 1）
        CLZ32 r17, r20
        CLZ32 r18, r16
        ADDI32 r18, r18, 32
        CMPEQI32 p1, r20, 0
        SEL32 r17, r18, r17, p1
        ADDI32 r17, r17, -8
        CMPLTI32 p1, r17, 0
        BR32 p1, .right1
        CMPEQI32 p1, r17, 0
        BR32 p1, .normed
        SUBR32 r22, r22, r17
        CMPGEI32 p1, r17, 32
        BR32 p1, .left32
        ADDI32 r18, r0, 32
        SUBR32 r18, r18, r17
        SHRR32 r19, r16, r18
        SHLR32 r20, r20, r17
        ORR32 r20, r20, r19
        SHLR32 r16, r16, r17
        JMP32 .normed
.left32:
        ADDI32 r18, r17, -32
        SHLR32 r20, r16, r18
        ADDI32 r16, r0, 0
        JMP32 .normed
.right1:
        ANDI32 r19, r16, 1
        SHRI32 r16, r16, 1
        SHLI32 r18, r20, 31
        ORR32 r16, r16, r18
        ORR32 r16, r16, r19
        SHRI32 r20, r20, 1
        ADDI32 r22, r22, 1
.normed:
        ; 指数が 1 より小さければ非正規化数：右へ k = 1 − 指数（こぼれた bit は最下位に）、指数は 1
        CMPGEI32 p1, r22, 1
        BR32 p1, .round
        ADDI32 r17, r0, 1
        SUBR32 r17, r17, r22
        ADDI32 r22, r0, 1
        CMPGEI32 p1, r17, 64
        BR32 p1, .sh64
        CMPGEI32 p1, r17, 32
        BR32 p1, .sh32
        ADDI32 r18, r0, 32
        SUBR32 r18, r18, r17
        SHLR32 r19, r16, r18
        CMPNEI32 p1, r19, 0
        BTOI32 r19, p1
        SHRR32 r16, r16, r17
        SHLR32 r21, r20, r18
        ORR32 r16, r16, r21
        ORR32 r16, r16, r19
        SHRR32 r20, r20, r17
        JMP32 .round
.sh32:  ADDI32 r18, r17, -32
        ADDI32 r19, r0, 64
        SUBR32 r19, r19, r17
        SHLR32 r21, r20, r19
        CMPEQI32 p1, r18, 0
        SEL32 r21, r0, r21, p1          ; k = 32 なら上位の語からはこぼれない
        ORR32 r21, r21, r16
        CMPNEI32 p1, r21, 0
        BTOI32 r21, p1
        SHRR32 r16, r20, r18
        ORR32 r16, r16, r21
        ADDI32 r20, r0, 0
        JMP32 .round
.sh64:  ORR32 r16, r16, r20
        CMPNEI32 p1, r16, 0
        BTOI32 r16, p1
        ADDI32 r20, r0, 0
.round: ; 下の 3 bit で丸める（最近接偶数：3 bit ＋ 残る最下位 bit が 5 以上なら切り上げ）
        ANDI32 r17, r16, 7
        SHRI32 r16, r16, 3
        SHLI32 r18, r20, 29
        ORR32 r16, r16, r18
        SHRI32 r20, r20, 3
        ANDI32 r18, r16, 1
        ADDR32 r17, r17, r18
        CMPGEUI32 p1, r17, 5
        BTOI32 r17, p1
        ADDR32 r16, r16, r17
        CMPLTUR32 p1, r16, r17
        BTOI32 r18, p1
        ADDR32 r20, r20, r18
        ; 2^53 になったら右へ 1、指数 + 1
        SHRI32 r18, r20, 21
        CMPEQI32 p1, r18, 0
        BR32 p1, .fits
        SHRI32 r16, r16, 1
        SHLI32 r18, r20, 31
        ORR32 r16, r16, r18
        SHRI32 r20, r20, 1
        ADDI32 r22, r22, 1
.fits:  CMPGEI32 p1, r22, 0x7FF
        BR32 p1, .inf
        ; 暗黙の 1（bit 52）が指数に 1 足されるので、指数は − 1 して足す（非正規化数は指数 1 で、そのまま）
        ADDI32 r22, r22, -1
        SHLI32 r22, r22, 20
        ADDR32 r17, r20, r22
        ORR32 r17, r17, r25
        JMP32 ___mycpu_dret
.inf:   ADDI32 r16, r0, 0
        ORI32 r17, r25, 0x7FF00000
        JMP32 ___mycpu_dret

; @fn ___subdf3
; a − b = a + (−b)。b の符号をスタックの上で変えて ___adddf3 へ（引数の場所は呼んだ側が捨てる）
___subdf3:
        LOAD32_32 r16, sp, 12
        XORI32 r16, r16, 0x80000000
        STORE32_32 r16, sp, 12
        JMP32 ___adddf3

; @fn ___adddf3
___adddf3:
        ADDI32 sp, sp, -16
        STORE32_32 r24, sp, 0
        STORE32_32 r25, sp, 4
        STORE32_32 r26, sp, 8
        STORE32_32 r27, sp, 12
        LOAD32_32 r16, sp, 16
        LOAD32_32 r17, sp, 20
        LOAD32_32 r18, sp, 24
        LOAD32_32 r19, sp, 28
        ; 絶対値の大きい方を a に（r16:r17 が a、r18:r19 が b、r20・r21 は符号を除いた上位）
        ANDI32 r20, r17, 0x7FFFFFFF
        ANDI32 r21, r19, 0x7FFFFFFF
        CMPLTUR32 p1, r20, r21
        BR32 p1, .swap
        CMPNER32 p1, r20, r21
        BR32 p1, .ordered
        CMPGEUR32 p1, r16, r18
        BR32 p1, .ordered
.swap:  ADDR32 r22, r16, r0
        ADDR32 r16, r18, r0
        ADDR32 r18, r22, r0
        ADDR32 r22, r17, r0
        ADDR32 r17, r19, r0
        ADDR32 r19, r22, r0
        ADDR32 r22, r20, r0
        ADDR32 r20, r21, r0
        ADDR32 r21, r22, r0
.ordered:
        SHRI32 r22, r20, 20             ; a の指数
        SHRI32 r23, r21, 20             ; b の指数
        ANDI32 r25, r17, 0x80000000     ; 答えの符号（大きい方）
        CMPEQI32 p1, r22, 0x7FF
        BR32 p1, .special
        ORR32 r24, r21, r18
        CMPEQI32 p1, r24, 0
        BR32 p1, .bzero
        XORR32 r26, r17, r19            ; 符号が違えば負（引き算）
        ; 仮数：正規化数は暗黙の 1、非正規化数は指数を 1 に
        ANDI32 r20, r20, 0xFFFFF
        ANDI32 r21, r21, 0xFFFFF
        ADDI32 r24, r0, 1
        CMPEQI32 p1, r22, 0
        ORI32 r27, r20, 0x100000
        SEL32 r20, r20, r27, p1
        SEL32 r22, r24, r22, p1
        CMPEQI32 p1, r23, 0
        ORI32 r27, r21, 0x100000
        SEL32 r21, r21, r27, p1
        SEL32 r23, r24, r23, p1
        ; 左へ 3 bit（丸め用）
        SHLI32 r20, r20, 3
        SHRI32 r27, r16, 29
        ORR32 r20, r20, r27
        SHLI32 r16, r16, 3
        SHLI32 r21, r21, 3
        SHRI32 r27, r18, 29
        ORR32 r21, r21, r27
        SHLI32 r18, r18, 3
        ; b を右へ d = 指数の差（こぼれた bit は最下位に）
        SUBR32 r17, r22, r23
        CMPEQI32 p1, r17, 0
        BR32 p1, .aligned
        CMPGEI32 p1, r17, 64
        BR32 p1, .b64
        CMPGEI32 p1, r17, 32
        BR32 p1, .b32
        ADDI32 r19, r0, 32
        SUBR32 r19, r19, r17
        SHLR32 r24, r18, r19
        CMPNEI32 p1, r24, 0
        BTOI32 r24, p1
        SHRR32 r18, r18, r17
        SHLR32 r27, r21, r19
        ORR32 r18, r18, r27
        ORR32 r18, r18, r24
        SHRR32 r21, r21, r17
        JMP32 .aligned
.b32:   ADDI32 r19, r17, -32
        ADDI32 r24, r0, 64
        SUBR32 r24, r24, r17
        SHLR32 r27, r21, r24
        CMPEQI32 p1, r19, 0
        SEL32 r27, r0, r27, p1
        ORR32 r27, r27, r18
        CMPNEI32 p1, r27, 0
        BTOI32 r27, p1
        SHRR32 r18, r21, r19
        ORR32 r18, r18, r27
        ADDI32 r21, r0, 0
        JMP32 .aligned
.b64:   ADDI32 r18, r0, 1               ; 全部こぼれた（b は 0 でない）
        ADDI32 r21, r0, 0
.aligned:
        CMPLTI32 p1, r26, 0
        BR32 p1, .sub
        ADDR32 r16, r16, r18
        CMPLTUR32 p1, r16, r18
        BTOI32 r24, p1
        ADDR32 r20, r20, r21
        ADDR32 r20, r20, r24
        JMP32 ___mycpu_dpack
.sub:   CMPLTUR32 p1, r16, r18
        BTOI32 r24, p1
        SUBR32 r16, r16, r18
        SUBR32 r20, r20, r21
        SUBR32 r20, r20, r24
        ORR32 r24, r20, r16
        CMPNEI32 p1, r24, 0
        BR32 p1, ___mycpu_dpack
        ADDI32 r17, r0, 0               ; x − x = +0
        JMP32 ___mycpu_dret
.bzero: ; b = ±0：a も ±0 なら符号は両方の AND（−0 + −0 だけ −0）、でなければ a
        ORR32 r24, r20, r16
        CMPNEI32 p1, r24, 0
        BR32 p1, ___mycpu_dret
        ANDR32 r17, r17, r19
        JMP32 ___mycpu_dret
.special: ; a は無限大か NaN（b の方が大きくないので、b が NaN なら a も NaN）
        ANDI32 r24, r20, 0xFFFFF
        ORR32 r24, r24, r16
        CMPNEI32 p1, r24, 0
        BR32 p1, .nan
        CMPNEI32 p1, r23, 0x7FF
        BR32 p1, ___mycpu_dret          ; ∞ + 有限 = ∞
        XORR32 r24, r17, r19
        CMPLTI32 p1, r24, 0
        BR32 p1, .nan                   ; ∞ − ∞
        JMP32 ___mycpu_dret
.nan:   ADDI32 r16, r0, 0
        ADDI32 r17, r0, 0x7FF80000
        JMP32 ___mycpu_dret

; @fn ___muldf3
___muldf3:
        ADDI32 sp, sp, -16
        STORE32_32 r24, sp, 0
        STORE32_32 r25, sp, 4
        STORE32_32 r26, sp, 8
        STORE32_32 r27, sp, 12
        LOAD32_32 r16, sp, 16
        LOAD32_32 r17, sp, 20
        LOAD32_32 r18, sp, 24
        LOAD32_32 r19, sp, 28
        XORR32 r25, r17, r19
        ANDI32 r25, r25, 0x80000000     ; 答えの符号
        ANDI32 r20, r17, 0x7FFFFFFF
        ANDI32 r21, r19, 0x7FFFFFFF
        SHRI32 r22, r20, 20
        SHRI32 r23, r21, 20
        ANDI32 r20, r20, 0xFFFFF
        ANDI32 r21, r21, 0xFFFFF
        CMPEQI32 p1, r22, 0x7FF
        BR32 p1, .aspec
        CMPEQI32 p1, r23, 0x7FF
        BR32 p1, .bspec
        ORR32 r24, r20, r16
        ORR32 r24, r24, r22
        CMPEQI32 p1, r24, 0
        BR32 p1, .zero
        ORR32 r24, r21, r18
        ORR32 r24, r24, r23
        CMPEQI32 p1, r24, 0
        BR32 p1, .zero
        ; a の仮数 r20:r16（先頭の 1 を bit 52 に。非正規化数は左へずらして指数を減らす）
        CMPEQI32 p1, r22, 0
        BR32 p1, .adn
        ORI32 r20, r20, 0x100000
        JMP32 .bnorm
.adn:   CLZ32 r24, r20
        CLZ32 r26, r16
        ADDI32 r26, r26, 32
        CMPEQI32 p1, r20, 0
        SEL32 r24, r26, r24, p1
        ADDI32 r24, r24, -11            ; n（1 以上）
        ADDI32 r22, r0, 1
        SUBR32 r22, r22, r24
        CMPGEI32 p1, r24, 32
        BR32 p1, .adn32
        ADDI32 r26, r0, 32
        SUBR32 r26, r26, r24
        SHRR32 r27, r16, r26
        SHLR32 r20, r20, r24
        ORR32 r20, r20, r27
        SHLR32 r16, r16, r24
        JMP32 .bnorm
.adn32: ADDI32 r26, r24, -32
        SHLR32 r20, r16, r26
        ADDI32 r16, r0, 0
.bnorm: ; b の仮数 r21:r18
        CMPEQI32 p1, r23, 0
        BR32 p1, .bdn
        ORI32 r21, r21, 0x100000
        JMP32 .mul
.bdn:   CLZ32 r24, r21
        CLZ32 r26, r18
        ADDI32 r26, r26, 32
        CMPEQI32 p1, r21, 0
        SEL32 r24, r26, r24, p1
        ADDI32 r24, r24, -11
        ADDI32 r23, r0, 1
        SUBR32 r23, r23, r24
        CMPGEI32 p1, r24, 32
        BR32 p1, .bdn32
        ADDI32 r26, r0, 32
        SUBR32 r26, r26, r24
        SHRR32 r27, r18, r26
        SHLR32 r21, r21, r24
        ORR32 r21, r21, r27
        SHLR32 r18, r18, r24
        JMP32 .mul
.bdn32: ADDI32 r26, r24, -32
        SHLR32 r21, r18, r26
        ADDI32 r18, r0, 0
.mul:   ; 53bit × 53bit → 106bit（w3:w2:w1:w0）。a = r20:r16、b = r21:r18
        ADDR32 r22, r22, r23
        ADDI32 r22, r22, -1023          ; 指数
        MULR32 r24, r16, r18            ; w0
        MULHUR32 r26, r16, r18
        MULR32 r27, r16, r21
        MULHUR32 r17, r16, r21
        ADDR32 r26, r26, r27
        CMPLTUR32 p1, r26, r27
        BTOI32 r23, p1
        MULR32 r27, r20, r18
        MULHUR32 r19, r20, r18
        ADDR32 r26, r26, r27            ; w1
        CMPLTUR32 p1, r26, r27
        BTOI32 r27, p1
        ADDR32 r23, r23, r27
        ADDR32 r17, r17, r19
        ADDR32 r17, r17, r23
        MULR32 r18, r20, r21
        MULHUR32 r19, r20, r21
        ADDR32 r17, r17, r18            ; w2
        CMPLTUR32 p1, r17, r18
        BTOI32 r27, p1
        ADDR32 r19, r19, r27            ; w3
        ; 先頭は bit 104 か 105 → 右へ 49（先頭は bit 55 か 56）、こぼれた bit は最下位に
        SHRI32 r16, r26, 17
        SHLI32 r27, r17, 15
        ORR32 r16, r16, r27
        SHRI32 r20, r17, 17
        SHLI32 r27, r19, 15
        ORR32 r20, r20, r27
        ANDI32 r26, r26, 0x1FFFF
        ORR32 r26, r26, r24
        CMPNEI32 p1, r26, 0
        BTOI32 r26, p1
        ORR32 r16, r16, r26
        JMP32 ___mycpu_dpack
.aspec: ; a は無限大か NaN
        ORR32 r24, r20, r16
        CMPNEI32 p1, r24, 0
        BR32 p1, .nan
        CMPNEI32 p1, r23, 0x7FF
        BR32 p1, .ainf
        ORR32 r24, r21, r18
        CMPNEI32 p1, r24, 0
        BR32 p1, .nan                   ; b が NaN
        JMP32 .inf
.ainf:  ORR32 r24, r21, r18
        ORR32 r24, r24, r23
        CMPEQI32 p1, r24, 0
        BR32 p1, .nan                   ; ∞ × 0
        JMP32 .inf
.bspec: ; a は有限、b は無限大か NaN
        ORR32 r24, r21, r18
        CMPNEI32 p1, r24, 0
        BR32 p1, .nan
        ORR32 r24, r20, r16
        ORR32 r24, r24, r22
        CMPEQI32 p1, r24, 0
        BR32 p1, .nan                   ; 0 × ∞
.inf:   ADDI32 r16, r0, 0
        ORI32 r17, r25, 0x7FF00000
        JMP32 ___mycpu_dret
.zero:  ADDI32 r16, r0, 0
        ADDR32 r17, r25, r0
        JMP32 ___mycpu_dret
.nan:   ADDI32 r16, r0, 0
        ADDI32 r17, r0, 0x7FF80000
        JMP32 ___mycpu_dret

; @fn ___divdf3
___divdf3:
        ADDI32 sp, sp, -16
        STORE32_32 r24, sp, 0
        STORE32_32 r25, sp, 4
        STORE32_32 r26, sp, 8
        STORE32_32 r27, sp, 12
        LOAD32_32 r16, sp, 16
        LOAD32_32 r17, sp, 20
        LOAD32_32 r18, sp, 24
        LOAD32_32 r19, sp, 28
        XORR32 r25, r17, r19
        ANDI32 r25, r25, 0x80000000
        ANDI32 r20, r17, 0x7FFFFFFF
        ANDI32 r21, r19, 0x7FFFFFFF
        SHRI32 r22, r20, 20
        SHRI32 r23, r21, 20
        ANDI32 r20, r20, 0xFFFFF
        ANDI32 r21, r21, 0xFFFFF
        CMPEQI32 p1, r22, 0x7FF
        BR32 p1, .aspec
        CMPEQI32 p1, r23, 0x7FF
        BR32 p1, .bspec
        ORR32 r24, r21, r18
        ORR32 r24, r24, r23
        CMPEQI32 p1, r24, 0
        BR32 p1, .bzero
        ORR32 r24, r20, r16
        ORR32 r24, r24, r22
        CMPEQI32 p1, r24, 0
        BR32 p1, .zero
        ; 仮数（先頭の 1 を bit 52 に）。___muldf3 と同じ
        CMPEQI32 p1, r22, 0
        BR32 p1, .adn
        ORI32 r20, r20, 0x100000
        JMP32 .bnorm
.adn:   CLZ32 r24, r20
        CLZ32 r26, r16
        ADDI32 r26, r26, 32
        CMPEQI32 p1, r20, 0
        SEL32 r24, r26, r24, p1
        ADDI32 r24, r24, -11
        ADDI32 r22, r0, 1
        SUBR32 r22, r22, r24
        CMPGEI32 p1, r24, 32
        BR32 p1, .adn32
        ADDI32 r26, r0, 32
        SUBR32 r26, r26, r24
        SHRR32 r27, r16, r26
        SHLR32 r20, r20, r24
        ORR32 r20, r20, r27
        SHLR32 r16, r16, r24
        JMP32 .bnorm
.adn32: ADDI32 r26, r24, -32
        SHLR32 r20, r16, r26
        ADDI32 r16, r0, 0
.bnorm: CMPEQI32 p1, r23, 0
        BR32 p1, .bdn
        ORI32 r21, r21, 0x100000
        JMP32 .div
.bdn:   CLZ32 r24, r21
        CLZ32 r26, r18
        ADDI32 r26, r26, 32
        CMPEQI32 p1, r21, 0
        SEL32 r24, r26, r24, p1
        ADDI32 r24, r24, -11
        ADDI32 r23, r0, 1
        SUBR32 r23, r23, r24
        CMPGEI32 p1, r24, 32
        BR32 p1, .bdn32
        ADDI32 r26, r0, 32
        SUBR32 r26, r26, r24
        SHRR32 r27, r18, r26
        SHLR32 r21, r21, r24
        ORR32 r21, r21, r27
        SHLR32 r18, r18, r24
        JMP32 .div
.bdn32: ADDI32 r26, r24, -32
        SHLR32 r21, r18, r26
        ADDI32 r18, r0, 0
.div:   ; 筆算：商 q = a ÷ b × 2^55 を 56 bit（上 24 bit を r26、下 32 bit を r27）。余り r20:r16
        SUBR32 r22, r22, r23
        ADDI32 r22, r22, 1023           ; 指数
        ADDI32 r26, r0, 0
        ADDI32 r17, r0, 24
.q1:    CMPLTUR32 p2, r16, r18
        BTOI32 r24, p2
        SUBR32 r23, r20, r21
        SUBR32 r23, r23, r24            ; 余り − b の上位（負なら引けない）
        CMPGEI32 p1, r23, 0
        SUBR32 r24, r16, r18
        SEL32 r20, r23, r20, p1
        SEL32 r16, r24, r16, p1
        BTOI32 r24, p1
        ADDR32 r26, r26, r26
        ORR32 r26, r26, r24
        ADDR32 r20, r20, r20
        SHRI32 r24, r16, 31
        ORR32 r20, r20, r24
        ADDR32 r16, r16, r16
        ADDI32 r17, r17, -1
        CMPNEI32 p3, r17, 0
        BR32 p3, .q1
        ADDI32 r27, r0, 0
        ADDI32 r17, r0, 32
.q2:    CMPLTUR32 p2, r16, r18
        BTOI32 r24, p2
        SUBR32 r23, r20, r21
        SUBR32 r23, r23, r24
        CMPGEI32 p1, r23, 0
        SUBR32 r24, r16, r18
        SEL32 r20, r23, r20, p1
        SEL32 r16, r24, r16, p1
        BTOI32 r24, p1
        ADDR32 r27, r27, r27
        ORR32 r27, r27, r24
        ADDR32 r20, r20, r20
        SHRI32 r24, r16, 31
        ORR32 r20, r20, r24
        ADDR32 r16, r16, r16
        ADDI32 r17, r17, -1
        CMPNEI32 p3, r17, 0
        BR32 p3, .q2
        ; 余りがあれば最下位を 1 に
        ORR32 r20, r20, r16
        CMPNEI32 p1, r20, 0
        BTOI32 r20, p1
        ORR32 r16, r27, r20
        ADDR32 r20, r26, r0
        JMP32 ___mycpu_dpack
.aspec: ; a は無限大か NaN
        ORR32 r24, r20, r16
        CMPNEI32 p1, r24, 0
        BR32 p1, .nan
        CMPEQI32 p1, r23, 0x7FF
        BR32 p1, .nan                   ; ∞ ÷ ∞、∞ ÷ NaN
        JMP32 .inf
.bspec: ; a は有限、b は無限大か NaN
        ORR32 r24, r21, r18
        CMPNEI32 p1, r24, 0
        BR32 p1, .nan
        JMP32 .zero                     ; 有限 ÷ ∞ = 0
.bzero: ORR32 r24, r20, r16
        ORR32 r24, r24, r22
        CMPEQI32 p1, r24, 0
        BR32 p1, .nan                   ; 0 ÷ 0
.inf:   ADDI32 r16, r0, 0
        ORI32 r17, r25, 0x7FF00000
        JMP32 ___mycpu_dret
.zero:  ADDI32 r16, r0, 0
        ADDR32 r17, r25, r0
        JMP32 ___mycpu_dret
.nan:   ADDI32 r16, r0, 0
        ADDI32 r17, r0, 0x7FF80000
        JMP32 ___mycpu_dret

; @fn ___mycpu_dcmp
; 比べる：r16 = −1（a < b）・0（等しい）・1（a > b）・2（どちらかが NaN）。+0 と −0 は等しい
___mycpu_dcmp:
        LOAD32_32 r16, sp, 0
        LOAD32_32 r17, sp, 4
        LOAD32_32 r18, sp, 8
        LOAD32_32 r19, sp, 12
        ; NaN：符号を除いた上位が 0x7FF00000 より大きい、または等しくて下位が 0 でない
        ANDI32 r20, r17, 0x7FFFFFFF
        ANDI32 r21, r19, 0x7FFFFFFF
        ADDI32 r23, r0, 0x7FF00000
        CMPNEI32 p1, r16, 0
        BTOI32 r22, p1
        ORR32 r22, r22, r20
        CMPLTUR32 p1, r23, r22
        BR32 p1, .nan
        CMPNEI32 p1, r18, 0
        BTOI32 r22, p1
        ORR32 r22, r22, r21
        CMPLTUR32 p1, r23, r22
        BR32 p1, .nan
        ORR32 r22, r20, r21
        ORR32 r22, r22, r16
        ORR32 r22, r22, r18
        CMPEQI32 p1, r22, 0
        BR32 p1, .eq                    ; ±0 と ±0
        ; 負の数は符号以外を反転すると、64bit の符号付き整数として大小が比べられる
        SARI32 r22, r17, 31
        XORR32 r16, r16, r22
        SHRI32 r22, r22, 1
        XORR32 r17, r17, r22
        SARI32 r22, r19, 31
        XORR32 r18, r18, r22
        SHRI32 r22, r22, 1
        XORR32 r19, r19, r22
        CMPLTR32 p1, r17, r19
        BR32 p1, .lt
        CMPNER32 p1, r17, r19
        BR32 p1, .gt
        CMPLTUR32 p1, r16, r18
        BR32 p1, .lt
        CMPNER32 p1, r16, r18
        BR32 p1, .gt
.eq:    ADDI32 r16, r0, 0
        RET32
.lt:    ADDI32 r16, r0, -1
        RET32
.gt:    ADDI32 r16, r0, 1
        RET32
.nan:   ADDI32 r16, r0, 2
        RET32

; @fn ___floatsidf
; int → double（いつも正確）
___floatsidf:
        CMPEQI32 p1, r16, 0
        BR32 p1, .zero
        SARI32 r19, r16, 31
        XORR32 r16, r16, r19
        SUBR32 r16, r16, r19            ; 絶対値（−2^31 も符号なしで正しい）
        ANDI32 r19, r19, 0x80000000
        JMP32 ___mycpu_u32d
.zero:  ADDI32 r17, r0, 0
        RET32

; @fn ___floatunsidf
___floatunsidf:
        CMPEQI32 p1, r16, 0
        BR32 p1, .zero
        ADDI32 r19, r0, 0
        JMP32 ___mycpu_u32d
.zero:  ADDI32 r17, r0, 0
        RET32

; @fn ___mycpu_u32d
; r16（0 以外の符号なし整数）と符号 r19 → double（r16・r17）
___mycpu_u32d:
        CLZ32 r18, r16
        SHLR32 r16, r16, r18
        SHLI32 r16, r16, 1              ; 先頭の 1 を捨てる
        SHRI32 r17, r16, 12
        SHLI32 r16, r16, 20
        ADDI32 r20, r0, 1054            ; 指数 = 1023 + 31 − clz
        SUBR32 r20, r20, r18
        SHLI32 r20, r20, 20
        ORR32 r17, r17, r20
        ORR32 r17, r17, r19
        RET32

; @fn ___fixdfsi
; double → int（0 の方へ切り捨て。入りきらなければいちばん大きい・小さい値、NaN は 0）
___fixdfsi:
        LOAD32_32 r16, sp, 0
        LOAD32_32 r17, sp, 4
        ANDI32 r18, r17, 0x7FFFFFFF
        ADDI32 r20, r0, 0x7FF00000
        CMPNEI32 p1, r16, 0
        BTOI32 r19, p1
        ORR32 r19, r19, r18
        CMPLTUR32 p1, r20, r19
        BR32 p1, .zero                  ; NaN
        SHRI32 r19, r18, 20
        ADDI32 r19, r19, -1023          ; sh：値は 2^sh 以上 2^(sh+1) 未満
        CMPLTI32 p1, r19, 0
        BR32 p1, .zero
        CMPGEI32 p1, r19, 31
        BR32 p1, .sat
        ; 仮数の上 32 bit（先頭の 1 が bit 31）を右へ 31 − sh
        ANDI32 r18, r18, 0xFFFFF
        ORI32 r18, r18, 0x100000
        SHLI32 r18, r18, 11
        SHRI32 r16, r16, 21
        ORR32 r18, r18, r16
        ADDI32 r20, r0, 31
        SUBR32 r20, r20, r19
        SHRR32 r16, r18, r20
        CMPLTI32 p1, r17, 0
        BR32 p1, .neg
        RET32
.neg:   SUBR32 r16, r0, r16
        RET32
.sat:   ADDI32 r16, r0, 0x7FFFFFFF
        ADDI32 r18, r0, 0x80000000
        CMPLTI32 p1, r17, 0
        SEL32 r16, r18, r16, p1
        RET32
.zero:  ADDI32 r16, r0, 0
        RET32

; @fn ___fixunsdfsi
; double → unsigned（負と NaN は 0、入りきらなければ 0xFFFFFFFF）
___fixunsdfsi:
        LOAD32_32 r16, sp, 0
        LOAD32_32 r17, sp, 4
        CMPLTI32 p1, r17, 0
        BR32 p1, .zero
        ADDI32 r20, r0, 0x7FF00000
        CMPNEI32 p1, r16, 0
        BTOI32 r19, p1
        ORR32 r19, r19, r17
        CMPLTUR32 p1, r20, r19
        BR32 p1, .zero                  ; NaN
        SHRI32 r19, r17, 20
        ADDI32 r19, r19, -1023
        CMPLTI32 p1, r19, 0
        BR32 p1, .zero
        CMPGEI32 p1, r19, 32
        BR32 p1, .sat
        ANDI32 r18, r17, 0xFFFFF
        ORI32 r18, r18, 0x100000
        SHLI32 r18, r18, 11
        SHRI32 r16, r16, 21
        ORR32 r18, r18, r16
        ADDI32 r20, r0, 31
        SUBR32 r20, r20, r19
        SHRR32 r16, r18, r20
        RET32
.sat:   ADDI32 r16, r0, -1
        RET32
.zero:  ADDI32 r16, r0, 0
        RET32

; ---- float（32bit）：計算は double に広げてする（libc/softfloat.c の __addsf3 など）。ここは広げる・丸める・比べる・変換 ----

; @fn ___extendsfdf2
; float（r16）→ double（いつも正確）
___extendsfdf2:
        ANDI32 r19, r16, 0x80000000     ; 符号
        SHRI32 r18, r16, 23
        ANDI32 r18, r18, 0xFF           ; 指数
        ANDI32 r16, r16, 0x7FFFFF       ; 仮数
        CMPEQI32 p1, r18, 0xFF
        BR32 p1, .special
        CMPEQI32 p1, r18, 0
        BR32 p1, .small
.pack:  ADDI32 r18, r18, 896            ; 1023 − 127
        SHLI32 r18, r18, 20
        SHRI32 r17, r16, 3
        ORR32 r17, r17, r18
        ORR32 r17, r17, r19
        SHLI32 r16, r16, 29
        RET32
.small: CMPEQI32 p1, r16, 0
        BR32 p1, .zero
        CLZ32 r20, r16                  ; 非正規化数：先頭の 1 を bit 23 に（それは捨てる）
        ADDI32 r20, r20, -8
        SHLR32 r16, r16, r20
        ANDI32 r16, r16, 0x7FFFFF
        ADDI32 r18, r0, 1
        SUBR32 r18, r18, r20
        JMP32 .pack
.zero:  ADDR32 r17, r19, r0
        RET32
.special: ; 無限大はそのまま、NaN は静かな NaN（仮数の先頭を 1 に）
        CMPEQI32 p1, r16, 0
        ORI32 r17, r19, 0x7FF00000
        BR32 p1, .inf
        ORI32 r17, r17, 0x80000
        SHRI32 r18, r16, 3
        ORR32 r17, r17, r18
        SHLI32 r16, r16, 29
        RET32
.inf:   ADDI32 r16, r0, 0
        RET32

; @fn ___truncdfsf2
; double（スタック）→ float（r16）。最近接偶数に丸める
___truncdfsf2:
        LOAD32_32 r16, sp, 0
        LOAD32_32 r17, sp, 4
        ANDI32 r19, r17, 0x80000000     ; 符号
        ANDI32 r18, r17, 0x7FFFFFFF
        SHRI32 r20, r18, 20             ; double の指数
        CMPEQI32 p1, r20, 0x7FF
        BR32 p1, .special
        CMPEQI32 p1, r20, 0
        BR32 p1, .zero                  ; 0 と double の非正規化数（float では 0 に丸まる）
        ADDI32 r20, r20, -896           ; float の指数
        CMPGEI32 p1, r20, 0xFF
        BR32 p1, .inf
        ; t = 仮数の上 31 bit（先頭の 1 が bit 30）。下 7 bit は丸め用、こぼれた bit は最下位に
        ANDI32 r18, r18, 0xFFFFF
        ORI32 r18, r18, 0x100000
        SHLI32 r18, r18, 10
        SHRI32 r21, r16, 22
        ORR32 r18, r18, r21
        ANDI32 r16, r16, 0x3FFFFF
        CMPNEI32 p1, r16, 0
        BTOI32 r16, p1
        ORR32 r18, r18, r16
        CMPGEI32 p1, r20, 1
        BR32 p1, .round
        ; float の非正規化数：右へ 1 − 指数（こぼれた bit は最下位に）、指数は 1
        ADDI32 r21, r0, 1
        SUBR32 r21, r21, r20
        ADDI32 r20, r0, 1
        CMPGEI32 p1, r21, 31
        BR32 p1, .tiny
        ADDI32 r22, r0, 32
        SUBR32 r22, r22, r21
        SHLR32 r23, r18, r22
        CMPNEI32 p1, r23, 0
        BTOI32 r23, p1
        SHRR32 r18, r18, r21
        ORR32 r18, r18, r23
        JMP32 .round
.tiny:  ADDI32 r18, r0, 1               ; 全部こぼれた（0 ではない）
.round: ANDI32 r21, r18, 0x7F
        SHRI32 r18, r18, 7
        ANDI32 r22, r18, 1
        ADDR32 r21, r21, r22
        CMPGEUI32 p1, r21, 0x41
        BTOI32 r21, p1
        ADDR32 r18, r18, r21
        ; 指数 − 1 を足す（暗黙の 1 と丸めの繰り上がりは指数に入る。0xFF になれば無限大）
        ADDI32 r20, r20, -1
        SHLI32 r20, r20, 23
        ADDR32 r16, r18, r20
        ORR32 r16, r16, r19
        RET32
.special: ; NaN は 0x7FC00000（符号なし）、無限大はそのまま
        ANDI32 r18, r18, 0xFFFFF
        ORR32 r18, r18, r16
        CMPNEI32 p1, r18, 0
        BR32 p1, .nan
.inf:   ORI32 r16, r19, 0x7F800000
        RET32
.nan:   ADDI32 r16, r0, 0x7FC00000
        RET32
.zero:  ADDR32 r16, r19, r0
        RET32

; @fn ___mycpu_fcmp
; float を比べる（r16・r17）：−1・0・1、どちらかが NaN なら 2。+0 と −0 は等しい
___mycpu_fcmp:
        ADDI32 r20, r0, 0x7F800000
        ANDI32 r18, r16, 0x7FFFFFFF
        ANDI32 r19, r17, 0x7FFFFFFF
        CMPLTUR32 p1, r20, r18
        BR32 p1, .nan
        CMPLTUR32 p1, r20, r19
        BR32 p1, .nan
        ORR32 r20, r18, r19
        CMPEQI32 p1, r20, 0
        BR32 p1, .eq
        SARI32 r20, r16, 31
        SHRI32 r20, r20, 1
        XORR32 r16, r16, r20
        SARI32 r20, r17, 31
        SHRI32 r20, r20, 1
        XORR32 r17, r17, r20
        CMPLTR32 p1, r16, r17
        BR32 p1, .lt
        CMPNER32 p1, r16, r17
        BR32 p1, .gt
.eq:    ADDI32 r16, r0, 0
        RET32
.lt:    ADDI32 r16, r0, -1
        RET32
.gt:    ADDI32 r16, r0, 1
        RET32
.nan:   ADDI32 r16, r0, 2
        RET32

; @fn ___floatsisf
; int → float（最近接偶数に丸める）
___floatsisf:
        CMPEQI32 p1, r16, 0
        BR32 p1, .zero
        SARI32 r19, r16, 31
        XORR32 r16, r16, r19
        SUBR32 r16, r16, r19
        ANDI32 r19, r19, 0x80000000
        JMP32 ___mycpu_u32f
.zero:  RET32

; @fn ___floatunsisf
___floatunsisf:
        CMPEQI32 p1, r16, 0
        BR32 p1, .zero
        ADDI32 r19, r0, 0
        JMP32 ___mycpu_u32f
.zero:  RET32

; @fn ___mycpu_u32f
; r16（0 以外の符号なし整数）と符号 r19 → float（r16）
___mycpu_u32f:
        CLZ32 r18, r16
        SHLR32 r16, r16, r18            ; 先頭の 1 が bit 31
        ANDI32 r20, r16, 0xFF           ; 丸め用の 8 bit（こぼれる bit はこれで全部）
        SHRI32 r16, r16, 8
        ANDI32 r21, r16, 1
        ADDR32 r20, r20, r21
        CMPGEUI32 p1, r20, 0x81
        BTOI32 r20, p1
        ADDR32 r16, r16, r20
        ADDI32 r20, r0, 157             ; 指数 − 1 = 127 + 31 − clz − 1
        SUBR32 r20, r20, r18
        SHLI32 r20, r20, 23
        ADDR32 r16, r16, r20
        ORR32 r16, r16, r19
        RET32

; @fn ___fixsfsi
; float → int（0 の方へ切り捨て。入りきらなければいちばん大きい・小さい値、NaN は 0）
___fixsfsi:
        ANDI32 r18, r16, 0x7FFFFFFF
        ADDI32 r20, r0, 0x7F800000
        CMPLTUR32 p1, r20, r18
        BR32 p1, .zero
        SHRI32 r19, r18, 23
        ADDI32 r19, r19, -127
        CMPLTI32 p1, r19, 0
        BR32 p1, .zero
        CMPGEI32 p1, r19, 31
        BR32 p1, .sat
        ANDI32 r18, r18, 0x7FFFFF
        ORI32 r18, r18, 0x800000
        SHLI32 r18, r18, 8
        ADDI32 r20, r0, 31
        SUBR32 r20, r20, r19
        SHRR32 r18, r18, r20
        CMPLTI32 p1, r16, 0
        BR32 p1, .neg
        ADDR32 r16, r18, r0
        RET32
.neg:   SUBR32 r16, r0, r18
        RET32
.sat:   ADDI32 r18, r0, 0x7FFFFFFF
        ADDI32 r20, r0, 0x80000000
        CMPLTI32 p1, r16, 0
        SEL32 r16, r20, r18, p1
        RET32
.zero:  ADDI32 r16, r0, 0
        RET32

; @fn ___fixunssfsi
; float → unsigned（負と NaN は 0、入りきらなければ 0xFFFFFFFF）
___fixunssfsi:
        CMPLTI32 p1, r16, 0
        BR32 p1, .zero
        ADDI32 r20, r0, 0x7F800000
        CMPLTUR32 p1, r20, r16
        BR32 p1, .zero
        SHRI32 r19, r16, 23
        ADDI32 r19, r19, -127
        CMPLTI32 p1, r19, 0
        BR32 p1, .zero
        CMPGEI32 p1, r19, 32
        BR32 p1, .sat
        ANDI32 r18, r16, 0x7FFFFF
        ORI32 r18, r18, 0x800000
        SHLI32 r18, r18, 8
        ADDI32 r20, r0, 31
        SUBR32 r20, r20, r19
        SHRR32 r16, r18, r20
        RET32
.sat:   ADDI32 r16, r0, -1
        RET32
.zero:  ADDI32 r16, r0, 0
        RET32
