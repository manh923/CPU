; よく呼ばれる文字列・メモリの関数をアセンブリで（C で書くより何倍も速い。cc の出すコードは素朴なので）
; 呼び出し規約どおり：引数 r16〜r18、戻り値 r16。壊すのは r16〜r23 だけ

; memcpy(r16 = 先, r17 = 元, r18 = バイト数) → 先。どちらも 4 バイト境界なら 16・4 バイトずつ
_memcpy:
        ADDR32 r19, r16, r0
        ORR32 r20, r16, r17
        ANDI32 r20, r20, 3
        CMPNEI32 p1, r20, 0
        BR32 p1, .bytes
.w16:   CMPLTUI32 p1, r18, 16
        BR32 p1, .w4
        LOAD32_32 r20, r17, 0
        LOAD32_32 r21, r17, 4
        LOAD32_32 r22, r17, 8
        LOAD32_32 r23, r17, 12
        STORE32_32 r20, r19, 0
        STORE32_32 r21, r19, 4
        STORE32_32 r22, r19, 8
        STORE32_32 r23, r19, 12
        ADDI32 r17, r17, 16
        ADDI32 r19, r19, 16
        ADDI32 r18, r18, -16
        JMP32 .w16
.w4:    CMPLTUI32 p1, r18, 4
        BR32 p1, .bytes
        LOAD32_32 r20, r17, 0
        STORE32_32 r20, r19, 0
        ADDI32 r17, r17, 4
        ADDI32 r19, r19, 4
        ADDI32 r18, r18, -4
        JMP32 .w4
.bytes: CMPEQI32 p1, r18, 0
        BR32 p1, .done
        LOAD8U_32 r20, r17, 0
        STORE8_32 r20, r19, 0
        ADDI32 r17, r17, 1
        ADDI32 r19, r19, 1
        ADDI32 r18, r18, -1
        JMP32 .bytes
.done:  RET32

; memset(r16 = 先, r17 = 値, r18 = バイト数) → 先。4 バイト境界からは 16・4 バイトずつ
_memset:
        ADDR32 r19, r16, r0
        ANDI32 r17, r17, 255
.al:    ANDI32 r20, r19, 3
        CMPEQI32 p1, r20, 0
        BR32 p1, .word
        CMPEQI32 p1, r18, 0
        BR32 p1, .done
        STORE8_32 r17, r19, 0
        ADDI32 r19, r19, 1
        ADDI32 r18, r18, -1
        JMP32 .al
.word:  MULI32 r20, r17, 0x01010101
.w16:   CMPLTUI32 p1, r18, 16
        BR32 p1, .w4
        STORE32_32 r20, r19, 0
        STORE32_32 r20, r19, 4
        STORE32_32 r20, r19, 8
        STORE32_32 r20, r19, 12
        ADDI32 r19, r19, 16
        ADDI32 r18, r18, -16
        JMP32 .w16
.w4:    CMPLTUI32 p1, r18, 4
        BR32 p1, .b
        STORE32_32 r20, r19, 0
        ADDI32 r19, r19, 4
        ADDI32 r18, r18, -4
        JMP32 .w4
.b:     CMPEQI32 p1, r18, 0
        BR32 p1, .done
        STORE8_32 r17, r19, 0
        ADDI32 r19, r19, 1
        ADDI32 r18, r18, -1
        JMP32 .b
.done:  RET32

; memchr(r16 = 場所, r17 = 文字, r18 = バイト数) → 見つけた番地か 0
_memchr:
        ANDI32 r17, r17, 255
.l:     CMPEQI32 p1, r18, 0
        BR32 p1, .no
        LOAD8U_32 r19, r16, 0
        CMPEQR32 p1, r19, r17
        BR32 p1, .yes
        ADDI32 r16, r16, 1
        ADDI32 r18, r18, -1
        JMP32 .l
.no:    ADDI32 r16, r0, 0
.yes:   RET32

; memcmp(r16 = a, r17 = b, r18 = バイト数) → 最初に違うバイトの差（符号なしで）、同じなら 0
_memcmp:
.l:     CMPEQI32 p1, r18, 0
        BR32 p1, .same
        LOAD8U_32 r19, r16, 0
        LOAD8U_32 r20, r17, 0
        CMPNER32 p1, r19, r20
        BR32 p1, .diff
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 1
        ADDI32 r18, r18, -1
        JMP32 .l
.same:  ADDI32 r16, r0, 0
        RET32
.diff:  SUBR32 r16, r19, r20
        RET32

; strlen(r16 = 文字列) → 長さ
_strlen:
        ADDR32 r17, r16, r0
.l:     LOAD8U_32 r18, r17, 0
        CMPEQI32 p1, r18, 0
        BR32 p1, .end
        ADDI32 r17, r17, 1
        JMP32 .l
.end:   SUBR32 r16, r17, r16
        RET32

; strcmp(r16 = a, r17 = b) → 最初に違う文字の差（符号なしで）
_strcmp:
.l:     LOAD8U_32 r18, r16, 0
        LOAD8U_32 r19, r17, 0
        CMPNER32 p1, r18, r19
        BR32 p1, .diff
        CMPEQI32 p1, r18, 0
        BR32 p1, .diff
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 1
        JMP32 .l
.diff:  SUBR32 r16, r18, r19
        RET32

; strncmp(r16 = a, r17 = b, r18 = 最大の文字数)
_strncmp:
.l:     CMPEQI32 p1, r18, 0
        BR32 p1, .same
        LOAD8U_32 r19, r16, 0
        LOAD8U_32 r20, r17, 0
        CMPNER32 p1, r19, r20
        BR32 p1, .diff
        CMPEQI32 p1, r19, 0
        BR32 p1, .same
        ADDI32 r16, r16, 1
        ADDI32 r17, r17, 1
        ADDI32 r18, r18, -1
        JMP32 .l
.same:  ADDI32 r16, r0, 0
        RET32
.diff:  SUBR32 r16, r19, r20
        RET32
