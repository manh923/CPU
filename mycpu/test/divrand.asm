; divrand.asm — 割り算の回路の確認：ランダムな数の DIV・DIVU・REM・REMU を 2000 組。
; 割られる数・割る数の大きさ（上の bit が 0 の数）と符号もばらばらにする。答えをまとめた値（r24）と最後の答え（r26〜r29）を、
; test/run.js が Verilog とシミュレータで比べる（止まったときのレジスタ）
start:
        ADDI32 r20, r0, 0x2545F491      ; 乱数（xorshift32）
        ADDI32 r24, r0, 0               ; 答えをまとめた値
        ADDI32 r25, r0, 2000
.loop:  CALL32 rnd
        ADDR32 r16, r20, r0             ; 割られる数：右へ 0〜31bit ずらす（半分は符号を残す）
        CALL32 rnd
        ANDI32 r22, r20, 31
        ANDI32 r23, r20, 32
        CMPEQI32 p1, r23, 0
        SARR32 r23, r16, r22
        SHRR32 r16, r16, r22
        SEL32 r16, r23, r16, p1
        CALL32 rnd                      ; 割る数：同じように小さくし、半分は負に。0 なら 7
        ADDR32 r17, r20, r0
        CALL32 rnd
        ANDI32 r22, r20, 31
        SHRR32 r17, r17, r22
        ANDI32 r23, r20, 64
        CMPNEI32 p1, r23, 0
        SUBR32 r23, r0, r17
        SEL32 r17, r23, r17, p1
        CMPEQI32 p1, r17, 0
        ADDI32 r23, r0, 7
        SEL32 r17, r23, r17, p1
        DIVR32 r26, r16, r17
        DIVUR32 r27, r16, r17
        REMR32 r28, r16, r17
        REMUR32 r29, r16, r17
        MULI32 r24, r24, 31
        ADDR32 r24, r24, r26
        MULI32 r24, r24, 31
        ADDR32 r24, r24, r27
        MULI32 r24, r24, 31
        ADDR32 r24, r24, r28
        MULI32 r24, r24, 31
        ADDR32 r24, r24, r29
        ADDI32 r25, r25, -1
        CMPNEI32 p1, r25, 0
        BR32 p1, .loop
        HLT

; rnd: r20 を次の乱数に。r21 を壊す
rnd:    SHLI32 r21, r20, 13
        XORR32 r20, r20, r21
        SHRI32 r21, r20, 17
        XORR32 r20, r20, r21
        SHLI32 r21, r20, 5
        XORR32 r20, r20, r21
        RET32
