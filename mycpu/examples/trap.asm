; trap.asm — 例外・ユーザーモード・タイマー割り込み（6 章）
UART_TX     = 0x00010000
UART_STATUS = 0x00010004
TIMER_COUNT = 0x00010010
TIMER_CMP   = 0x00010014
TIMER_CTRL  = 0x00010018
DATA        = 0x00020000

start:
        ADDI32 sp, r0, 0x00028000
        ADDI32 evec, r0, handler        ; ROM の最初の仕事は EVEC の設定（6.1）

        ; リセット直後の CAUSE は 0xFFFF（6.3）
        CMPNEI32 p1, cause, 0xFFFF
        BR32 p1, .noreset
        ADDI32 r16, r0, m_reset
        CALL32 puts
.noreset:
        SYSCALL                         ; → "syscall"、EPC+4 で戻る
        ADDI32 r24, r0, 1
        DIVI32 r24, r24, 0              ; → "divzero"、8 バイト飛ばす
        LOAD32_32 r24, r0, DATA + 2     ; → "align"
        ; ユーザーモードへ：EPC に入口、STATUS の「例外直前の特権」を 1 にして ERET
        ADDI32 epc, r0, user_entry
        ADDI32 status, r0, 0x4
        ERET

after_user:                             ; 特権違反のハンドラからここに来る（カーネルモード）
        ; タイマー：50µs 後に割り込み。STATUS の bit9（割り込み 1 のマスク）と bit1（許可）
        LOAD32_32 r24, r0, TIMER_COUNT
        ADDI32 r24, r24, 50
        STORE32_32 r24, r0, TIMER_CMP
        ADDI32 r24, r0, 1
        STORE32_32 r24, r0, TIMER_CTRL
        ADDI32 status, r0, 0x0202
        WFI                             ; 割り込みが来るまで待つ
        ADDI32 status, r0, 0
        ADDI32 r16, r0, m_done
        CALL32 puts
        HLT

user_entry:
        ADDI32 r16, r0, m_user
        CALL32 puts
        SYSCALL                         ; ユーザーから OS を呼ぶ
        HLT                             ; ユーザーモードでは特権違反

; ---- 例外ハンドラ ----
handler:
        ADDR32 r22, cause, r0
        CMPLTI32 p5, r22, 0             ; 最上位 bit が 1 なら外部割り込み
        BR32 p5, .irq
        CMPEQI32 p5, r22, 3
        BR32 p5, .syscall
        CMPEQI32 p5, r22, 4
        BR32 p5, .divzero
        CMPEQI32 p5, r22, 1
        BR32 p5, .align
        CMPEQI32 p5, r22, 2
        BR32 p5, .priv
        HLT
.syscall:
        ADDI32 r16, r0, m_sys
        CALL32 puts
        ADDI32 epc, epc, 4              ; SYSCALL は 4 バイト（6.1）
        ERET
.divzero:
        ADDI32 r16, r0, m_div
        CALL32 puts
        ADDI32 epc, epc, 8
        ERET
.align:
        ADDI32 r16, r0, m_align
        CALL32 puts
        ADDI32 epc, epc, 8
        ERET
.priv:
        ADDI32 r16, r0, m_priv
        CALL32 puts
        JMP32 after_user
.irq:
        ANDI32 r22, r22, 0xFF
        CMPNEI32 p5, r22, 1             ; 割り込み 1 = タイマー
        BR32 p5, .unknown
        ADDI32 r16, r0, m_timer
        CALL32 puts
        STORE32_32 r0, r0, TIMER_CTRL   ; タイマーを止める（止めないと割り込みが続く）
        ERET
.unknown:
        HLT

puts:
        ADDR32 r21, lr, r0
.next:  LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .end
.wait:  LOAD32_32 r19, r0, UART_STATUS
        ANDI32 r19, r19, 1
        CMPEQI32 p1, r19, 0
        BR32 p1, .wait
        STORE32_32 r17, r0, UART_TX
        ADDI32 r16, r16, 1
        JMP32 .next
.end:   JMPR32 r21

m_reset: .asciz "reset\n"
m_sys:   .asciz "syscall\n"
m_div:   .asciz "divzero\n"
m_align: .asciz "align\n"
m_user:  .asciz "user\n"
m_priv:  .asciz "priv\n"
m_timer: .asciz "timer\n"
m_done:  .asciz "done\n"
