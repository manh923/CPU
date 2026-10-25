// 自作CPU 32bit 版（isa-spec.md v0.8）
// 3 段のパイプライン：
//   F（命令を読む）：命令の口に番地を出す。メモリは 1 クロック後に 8 バイト（ヘッダと即値）を返す
//   E（実行）：解読・レジスタの読み出し・演算・分岐。演算の結果はこのクロックの終わりにレジスタへ書く。
//              分岐はここで決まる。飛ぶときは、先に読んでいた命令を捨てて飛び先から読み直す（1 クロックの損）
//   M（メモリ）：E で出した読み出しの返事を受け取り、レジスタに書く。そのレジスタを使う命令は 1 クロック待つ
// 掛け算は 1 クロック、割り算は 32 クロック。M 形式（メモリの値で演算）と SWAP は返事が来るまで E で待つ。
// 動作の基準は lib/cpu.js（シミュレータ）。食い違いはテストで見つける（UART・レジスタ・実行した命令の順番）。
//
// 命令の口：i_req と i_addr（4 バイト単位）を出し、i_gnt が 1 なら受け付けられた。
//   返事は後のクロックで i_rvalid が 1 になったとき：i_rdata = {i_addr+4 の 4 バイト, i_addr の 4 バイト}、
//   i_err[0]・[1] はそれぞれが読めなかった印（つながっていない番地）。同時に待てる要求は 1 つ。
// データの口：d_req・d_addr（4 バイト単位）・d_wstrb（0 なら読み出し）・d_wdata を出し、d_gnt で受け付け。
//   d_err はつながっていない番地か ROM への書き込み（同じクロックで分かる。このとき CPU は止まる）。
//   返事は後のクロックで d_rvalid（書き込みも返事が来る）。同時に待てる要求は 1 つ。
module mycpu_cpu (
  input  wire        clk,
  input  wire        rst,
  output reg         i_req,
  output reg  [31:0] i_addr,
  input  wire        i_gnt,
  input  wire        i_rvalid,
  input  wire [63:0] i_rdata,
  input  wire [1:0]  i_err,
  output reg         d_req,
  output reg  [31:0] d_addr,
  output reg  [3:0]  d_wstrb,
  output reg  [31:0] d_wdata,
  input  wire        d_gnt,
  input  wire        d_err,
  input  wire        d_rvalid,
  input  wire [31:0] d_rdata,
  input  wire [7:0]  irq,        // 外部割り込み 8 本（レベル）
  output wire        halted,
  output reg  [1:0]  halt_code   // 1 = HLT、2 = 不正命令、3 = バスエラー
);
`include "opcodes.vh"

  localparam [31:0] STATUS_MASK = 32'h0000_FF0F;  // STATUS の実装済み bit（6.2）
  localparam [31:0] CAUSE_RESET = 32'h0000_FFFF;  // 6.3
  localparam [31:0] C_ALIGN = 32'd1, C_PRIV = 32'd2, C_SYSCALL = 32'd3, C_DIVZERO = 32'd4;

  // E の状態
  localparam [2:0] E_RUN = 3'd0, E_MWAIT = 3'd1, E_MEXEC = 3'd2, E_SWAP1 = 3'd3, E_SWAP2 = 3'd4,
                   E_DIV = 3'd5, E_WFI = 3'd6, E_HALT = 3'd7;
  reg [2:0] es;
  assign halted = es == E_HALT;

  // ---- レジスタ ----
  reg [31:0] gpr [0:15];   // r16〜r31
  reg [7:1]  pr;           // r1〜r7（1bit）
  reg [31:0] sp, lr, epc, cause, evec, status;
  reg [31:0] mem_data;     // M 形式・SWAP で読んだ値

  // E にいる命令（pc はその命令の番地）
  reg        e_valid, e_badpc, e_seen;
  reg [31:0] pc, ir, imm;
  reg [1:0]  e_ferr;       // 読めなかった印（[0] ヘッダ、[1] 即値）

  // F：読み終えて E が空くのを待っている命令（1 つまで）と、返事待ちの要求
  reg        q_valid;
  reg [31:0] q_pc;
  reg [63:0] q_data;
  reg [1:0]  q_err;
  reg        f_out, f_kill;      // 返事待ちの要求がある・その返事は捨てる
  reg [31:0] f_aout, f_next;     // 返事待ちの要求の番地・次に読む番地

  // M：返事待ちの読み出し・書き込み
  reg        m_load, m_store;
  reg [5:0]  m_rd;
  reg [2:0]  m_op;
  reg [1:0]  m_lo;

  // ---- 命令のフィールド（2.1） ----
  wire [1:0]  width = ir[1:0];
  wire [3:0]  grp   = ir[5:2];
  wire [7:0]  op    = ir[13:6];
  wire [13:0] opc   = ir[13:0];
  wire [5:0]  rd    = ir[19:14];
  wire [5:0]  rs1   = ir[25:20];
  wire [5:0]  rs2   = ir[31:26];
  wire [1:0]  form  = op[1:0];   // 0 = R、1 = I、2 = M（5.1）
  wire [5:0]  num   = op[7:2];   // 演算の種類

  wire is_alu   = grp == 4'd1 || grp == 4'd2 || grp == 4'd3;
  wire is_sel   = grp == 4'd3 && op == 8'h18;
  wire is_unary = grp == 4'd2 && (op == 8'h18 || op == 8'h1C);
  wire is_load  = grp == 4'd4 && op < 8'h10;
  wire is_store = grp == 4'd4 && op[7:4] == 4'h1;
  wire is_swap  = grp == 4'd4 && op == 8'h20;
  wire is_mform = is_alu && !is_sel && !is_unary && form == 2'd2;
  wire is_div   = grp == 4'd1 && num >= 6'd5;
  wire [31:0] next_pc = pc + (width == 2'd0 ? 32'd4 : 32'd8);

  // ---- レジスタ欄の種類と幅の確認（3.3） ----
  localparam [2:0] C_NONE = 3'd0, C_DATA = 3'd1, C_P = 3'd2, C_ADDR = 3'd3, C_R32 = 3'd4, C_R64 = 3'd5;
  reg [2:0] c_rd, c_rs1, c_rs2;
  always @* begin
    c_rd = C_NONE; c_rs1 = C_NONE; c_rs2 = C_NONE;
    if (is_alu) begin
      c_rd  = (grp == 4'd3 && !is_sel) ? C_P : C_DATA;
      c_rs1 = C_DATA;
      if (!is_unary && form != 2'd1) c_rs2 = form == 2'd2 ? C_ADDR : C_DATA;
    end else if (grp == 4'd4) begin
      c_rs1 = C_ADDR;
      if (is_store) c_rs2 = C_DATA;
      else c_rd = C_DATA;
      if (is_swap) c_rs2 = C_DATA;
    end else if (grp == 4'd5) begin
      if (op == 8'h01) c_rs1 = C_P;
      if (op == 8'h04 || op == 8'h05) c_rs1 = C_ADDR;
    end else if (grp == 4'd6) begin
      if (op == 8'h02) begin c_rd = C_R32;  c_rs1 = C_R64; end
      if (op == 8'h03) begin c_rd = C_DATA; c_rs1 = C_P;   end
    end
  end

  function reg_ok(input [2:0] c, input [5:0] n, input dest);
    begin
      case (c)
        C_NONE: reg_ok = 1'b1;
        C_P:    reg_ok = n <= 6'd7;
        C_DATA: reg_ok = n == 6'd0 || (n >= 6'd16 && n <= 6'd31) || (n >= 6'd48 && n <= 6'd54 && !(dest && n == 6'd48));
        C_ADDR: reg_ok = n == 6'd0 || (n >= 6'd16 && n <= 6'd31) || (n >= 6'd48 && n <= 6'd54);
        C_R32:  reg_ok = n == 6'd0 || (n >= 6'd16 && n <= 6'd31);
        C_R64:  reg_ok = n == 6'd0;  // 32bit CPU に 64bit レジスタはない
        default: reg_ok = 1'b0;
      endcase
    end
  endfunction

  wire insn_ok = op_valid32(opc) && reg_ok(c_rd, rd, 1'b1) && reg_ok(c_rs1, rs1, 1'b0) && reg_ok(c_rs2, rs2, 1'b0);
  wire priv_dest = c_rd == C_DATA && rd >= 6'd51 && rd <= 6'd54;
  wire user = status[0];

  // ---- 演算 ----
  // レジスタの読み出し。関数にすると、シミュレーションでレジスタの変化が反映されない
  // （連続代入は関数の引数しか見ない）ので、always @* に直接書く。
  reg [31:0] a, bR;   // rs1・rs2 の値
  always @* begin
    a = 32'd0;
    if (rs1 >= 6'd1 && rs1 <= 6'd7) a = {31'd0, pr[rs1[2:0]]};
    else if (rs1 >= 6'd16 && rs1 <= 6'd31) a = gpr[rs1[3:0]];
    else case (rs1)
      6'd48: a = pc;          // その命令自身の番地（3.3）
      6'd49: a = sp;
      6'd50: a = lr;
      6'd51: a = epc;
      6'd52: a = cause;
      6'd53: a = evec;
      6'd54: a = status;
      default: a = 32'd0;
    endcase
  end
  always @* begin
    bR = 32'd0;
    if (rs2 >= 6'd1 && rs2 <= 6'd7) bR = {31'd0, pr[rs2[2:0]]};
    else if (rs2 >= 6'd16 && rs2 <= 6'd31) bR = gpr[rs2[3:0]];
    else case (rs2)
      6'd48: bR = pc;
      6'd49: bR = sp;
      6'd50: bR = lr;
      6'd51: bR = epc;
      6'd52: bR = cause;
      6'd53: bR = evec;
      6'd54: bR = status;
      default: bR = 32'd0;
    endcase
  end
  wire [31:0] b  = form == 2'd0 ? bR : form == 2'd1 ? imm : mem_data;
  wire [4:0]  sh = b[4:0];                 // シフト量は下位 5bit（5.4）

  wire msign = num == 6'd3;                // MULH だけ符号付き
  wire signed [32:0] ma = {msign & a[31], a};
  wire signed [32:0] mb = {msign & b[31], b};
  wire signed [65:0] prod = ma * mb;

  function [5:0] clz32(input [31:0] x);
    integer i;
    reg found;
    begin
      clz32 = 6'd0; found = 1'b0;
      for (i = 31; i >= 0; i = i - 1)
        if (!found) begin
          if (x[i]) found = 1'b1;
          else clz32 = clz32 + 6'd1;
        end
    end
  endfunction

  function [5:0] popcnt32(input [31:0] x);
    integer i;
    begin
      popcnt32 = 6'd0;
      for (i = 0; i < 32; i = i + 1) popcnt32 = popcnt32 + x[i];
    end
  endfunction

  reg [31:0] alu;
  always @* begin
    alu = 32'd0;
    case (grp)
      4'd1: case (num)
        6'd0: alu = a + b;
        6'd1: alu = a - b;
        6'd2: alu = prod[31:0];
        6'd3, 6'd4: alu = prod[63:32];
        default: alu = 32'd0;          // 除算は S_DIV で
      endcase
      4'd2: case (num)
        6'd0: alu = a & b;
        6'd1: alu = a | b;
        6'd2: alu = a ^ b;
        6'd3: alu = a << sh;
        6'd4: alu = a >> sh;
        6'd5: alu = $signed(a) >>> sh;
        6'd6: alu = {26'd0, clz32(a)};
        6'd7: alu = {26'd0, popcnt32(a)};
        default: alu = 32'd0;
      endcase
      4'd3: case (num)
        6'd0: alu = {31'd0, a == b};
        6'd1: alu = {31'd0, a != b};
        6'd2: alu = {31'd0, $signed(a) < $signed(b)};
        6'd3: alu = {31'd0, a < b};
        6'd4: alu = {31'd0, $signed(a) >= $signed(b)};
        6'd5: alu = {31'd0, a >= b};
        6'd6: alu = pr[imm[2:0]] && imm[2:0] != 3'd0 ? a : bR;  // SEL（p は即値の下位 6bit）
        default: alu = 32'd0;
      endcase
      default: alu = 32'd0;
    endcase
  end

  // ロード・ストアの番地（rs1 + imm、M 形式は rs2 + imm。32bit で回る）
  wire [31:0] ls_addr = a + imm;
  wire [31:0] m_addr  = bR + imm;
  wire [1:0]  ls_size = is_swap ? 2'd2 : is_store ? (op[1:0] == 2'd0 ? 2'd0 : op[1:0] == 2'd1 ? 2'd1 : 2'd2)
                                       : (op[2:1] == 2'd0 ? 2'd0 : op[2:1] == 2'd1 ? 2'd1 : 2'd2); // 0=1B 1=2B 2=4B
  wire ls_misaligned = (ls_size == 2'd1 && ls_addr[0]) || (ls_size == 2'd2 && ls_addr[1:0] != 2'd0);
  // M：読み出しの返事を、大きさと符号に合わせてそろえる
  wire [31:0] ld_shift = d_rdata >> {m_lo, 3'b000};
  reg  [31:0] ld_val;
  always @* begin
    case (m_op)
      3'd0: ld_val = {24'd0, ld_shift[7:0]};
      3'd1: ld_val = {{24{ld_shift[7]}}, ld_shift[7:0]};
      3'd2: ld_val = {16'd0, ld_shift[15:0]};
      3'd3: ld_val = {{16{ld_shift[15]}}, ld_shift[15:0]};
      default: ld_val = ld_shift;
    endcase
  end
  wire [3:0] st_strb = ls_size == 2'd0 ? (4'b0001 << ls_addr[1:0])
                     : ls_size == 2'd1 ? (4'b0011 << ls_addr[1:0]) : 4'b1111;
  wire [31:0] st_data = bR << {ls_addr[1:0], 3'b000};

  // ---- 割り込み（6.1） ----
  wire [7:0] irq_m = irq & status[15:8];
  reg  [2:0] irq_n;
  integer k;
  always @* begin
    irq_n = 3'd0;
    for (k = 7; k >= 0; k = k - 1) if (irq_m[k]) irq_n = k[2:0];
  end

  // ---- 除算（1 クロック 1bit、32 クロック。5.3） ----
  reg [31:0] div_q, div_b;
  reg [32:0] div_r;
  reg [5:0]  div_cnt;
  reg        div_negq, div_negr, div_rem;
  wire [32:0] div_try = {div_r[31:0], div_q[31]};
  wire        div_ge  = div_try >= {1'b0, div_b};
  wire [31:0] div_qres = div_negq ? -div_q : div_q;
  wire [31:0] div_rres = div_negr ? -div_r[31:0] : div_r[31:0];
  wire        div_signed = num == 6'd5 || num == 6'd7;

  // ---- 待つ条件（ハザード） ----
  // M の読み出しが終わっていないとき：その結果のレジスタを読む・書く命令（特殊レジスタなら全部）は待つ。
  // データの口を使う命令も、前の読み書きの返事が来るまで待つ（返事が来るクロックには出してよい）
  wire uses_d = is_mform || grp == 4'd4;
  wire m_dep  = m_load && m_rd != 6'd0 && (m_rd == rs1 || m_rd == rs2 || m_rd == rd || m_rd >= 6'd48);
  wire haz    = m_dep || ((m_load || m_store) && !d_rvalid && uses_d);

  // ---- データの口に出す要求（下の E の動きと同じ順に調べる。d_gnt・d_err を見ないので別に書く） ----
  wire e_ready = es == E_RUN && e_valid && !haz && !(status[1] && irq_m != 8'd0) && !e_badpc && !e_ferr[0] &&
                 insn_ok && !(width == 2'd1 && e_ferr[1]) && !(priv_dest && user);
  always @* begin
    d_req = 1'b0; d_addr = 32'd0; d_wstrb = 4'd0; d_wdata = 32'd0;
    if (e_ready && is_mform && m_addr[1:0] == 2'd0) begin
      d_req = 1'b1; d_addr = {m_addr[31:2], 2'b00};
    end else if (e_ready && grp == 4'd4 && !ls_misaligned) begin
      d_req = 1'b1; d_addr = {ls_addr[31:2], 2'b00};
      if (is_store) begin d_wstrb = st_strb; d_wdata = st_data; end
    end else if (es == E_SWAP2) begin
      d_req = 1'b1; d_addr = {ls_addr[31:2], 2'b00}; d_wstrb = 4'b1111; d_wdata = bR;
    end
  end

  // ---- E の動き（組み合わせ）：このクロックで何をするか ----
  reg        x_adv;              // 命令が E を出る（E が空のときも 1）
  reg        x_redir;            // 飛ぶ（読んであった命令を捨てて x_rpc から読む）
  reg [31:0] x_rpc;
  reg        x_rhold;            // 飛び先をこのクロックには読まない（自分を書き換えたとき）
  reg        x_wr;               // レジスタに書く
  reg [5:0]  x_wi;
  reg [31:0] x_wv;
  reg        x_exc;              // 例外・割り込みに入る
  reg [31:0] x_cause;
  reg        x_eret, x_halt, x_div, x_mload, x_mstore, x_latch, x_trace;
  reg [1:0]  x_hc;
  reg [2:0]  x_es;

  // 自分を書き換えるコード：書く 4 バイトが、読んである（読んでいる）命令の 8 バイトに重なるか
  wire [29:0] st_w = d_addr[31:2];
  function hit8(input [31:0] a, input [29:0] w);
    hit8 = a[31:2] == w || a[31:2] + 30'd1 == w;
  endfunction
  wire arr = i_rvalid && f_out && !f_kill;                         // 読んだ命令が届いた
  wire [31:0] seq_next = arr ? f_aout + (i_rdata[1:0] == 2'd0 ? 32'd4 : 32'd8) : f_next;
  wire st_hit = (q_valid && hit8(q_pc, st_w)) || (f_out && !f_kill && hit8(f_aout, st_w)) || hit8(seq_next, st_w);

  task t_fin;                    begin x_adv = 1'b1; x_es = E_RUN; end endtask
  task t_jump(input [31:0] t);   begin x_adv = 1'b1; x_es = E_RUN; x_redir = 1'b1; x_rpc = t; end endtask
  // 注意：always @* の中で呼ぶタスクは、引数でない信号を読まない（読んでも @* の対象にならない）
  task t_exc(input [31:0] c, input [31:0] vec); begin t_jump(vec); x_exc = 1'b1; x_cause = c; end endtask
  task t_halt(input [1:0] c);    begin x_halt = 1'b1; x_hc = c; x_es = E_HALT; end endtask
  task t_wr(input [5:0] n, input [31:0] v); begin x_wr = 1'b1; x_wi = n; x_wv = v; end endtask
  task t_stored(input hit, input [31:0] np);   // 書き込みを受け付けた：自分を書き換えていたら次の命令から読み直す
    begin
      x_mstore = 1'b1;
      if (hit) begin t_jump(np); x_rhold = 1'b1; end
      else t_fin;
    end
  endtask

  always @* begin
    x_adv = 1'b0; x_redir = 1'b0; x_rpc = 32'd0; x_rhold = 1'b0; x_wr = 1'b0; x_wi = 6'd0; x_wv = 32'd0;
    x_exc = 1'b0; x_cause = 32'd0; x_eret = 1'b0; x_halt = 1'b0; x_hc = 2'd0; x_div = 1'b0;
    x_mload = 1'b0; x_mstore = 1'b0; x_latch = 1'b0; x_trace = 1'b0; x_es = es;
    case (es)
      E_RUN:
        if (!e_valid) x_adv = 1'b1;
        else if (haz) ;
        else if (status[1] && irq_m != 8'd0) t_exc(32'h8000_0000 | irq_n, evec);   // 割り込みの印は bit31（6.3）
        else if (e_badpc) t_exc(C_ALIGN, evec);
        else if (e_ferr[0]) t_halt(2'd3);
        else if (!insn_ok) t_halt(2'd2);
        else if (width == 2'd1 && e_ferr[1]) t_halt(2'd3);
        else begin
          x_trace = !e_seen;
          if (priv_dest && user) t_exc(C_PRIV, evec);
          else case (grp)
            4'd0: begin  // システム（5.2）
              if (user && op != 8'h01 && op != 8'h03) t_exc(C_PRIV, evec);
              else case (op)
                8'h00: t_halt(2'd1);
                8'h01: t_fin;
                8'h02: begin x_eret = 1'b1; t_jump(epc); end
                8'h03: t_exc(C_SYSCALL, evec);
                default: x_es = E_WFI;
              endcase
            end
            4'd1, 4'd2, 4'd3: begin
              if (is_mform) begin
                if (m_addr[1:0] != 2'd0) t_exc(C_ALIGN, evec);
                else begin
                  if (d_err) t_halt(2'd3);
                  else if (d_gnt) x_es = E_MWAIT;
                end
              end else if (is_sel && imm[5:0] > 6'd7) t_halt(2'd2);
              else if (is_div) begin
                if (b == 32'd0) t_exc(C_DIVZERO, evec);
                else begin x_div = 1'b1; x_es = E_DIV; end
              end else begin t_wr(rd, alu); t_fin; end
            end
            4'd4: begin  // ロード・ストア（5.6）
              if (ls_misaligned) t_exc(C_ALIGN, evec);
              else begin
                if (d_err) t_halt(2'd3);
                else if (d_gnt) begin
                  if (is_swap) x_es = E_SWAP1;
                  else if (is_store) t_stored(st_hit, next_pc);
                  else begin x_mload = 1'b1; t_fin; end
                end
              end
            end
            4'd5: begin  // 分岐・呼び出し（5.7）
              case (op)
                8'h00: t_jump(imm);
                8'h01: if (pr[rs1[2:0]] && rs1 != 6'd0) t_jump(imm); else t_fin;
                8'h02: begin t_wr(6'd50, next_pc); t_jump(imm); end
                8'h03: t_jump(lr);
                8'h04: t_jump(a);
                default: begin t_wr(6'd50, next_pc); t_jump(a); end  // CALLR（飛び先は書き換え前の値）
              endcase
            end
            default: begin  // 幅変換（5.8）。32bit CPU で使えるのは TRUNC64TO32（r0 だけ）と BTOI32
              t_wr(rd, op == 8'h03 ? a : 32'd0);
              t_fin;
            end
          endcase
        end
      E_MWAIT: if (d_rvalid) begin x_latch = 1'b1; x_es = E_MEXEC; end
      E_MEXEC: begin           // M 形式：読んだ値（mem_data）で演算する
        if (is_div) begin
          if (b == 32'd0) t_exc(C_DIVZERO, evec);
          else begin x_div = 1'b1; x_es = E_DIV; end
        end else begin t_wr(rd, alu); t_fin; end
      end
      E_SWAP1: if (d_rvalid) begin x_latch = 1'b1; x_es = E_SWAP2; end
      E_SWAP2: begin
        if (d_err) t_halt(2'd3);
        else if (d_gnt) begin t_wr(rd, mem_data); t_stored(st_hit, next_pc); end
      end
      E_DIV: if (div_cnt == 6'd0) begin t_wr(rd, div_rem ? div_rres : div_qres); t_fin; end
      E_WFI: if (irq_m != 8'd0) t_fin;
      default: ;  // E_HALT
    endcase
  end

  // ---- F の動き（組み合わせ） ----
  // 次に E に入る命令は q か届いたもの。q が空くとわかっているときだけ次を読みに行く（返事の置き場があるように）
  wire q_nv = x_redir ? 1'b0 : x_adv ? (q_valid && arr) : (q_valid || arr);
  always @* begin
    i_addr = x_redir ? x_rpc : seq_next;
    i_req  = !halted && !x_halt && (!f_out || i_rvalid) && !q_nv && !x_rhold && i_addr[1:0] == 2'd0;
  end

  // ---- レジスタへの書き込み ----
  task write_reg(input [5:0] n, input [31:0] v);
    begin
      if (n >= 6'd1 && n <= 6'd7) pr[n[2:0]] <= v != 32'd0;
      else if (n >= 6'd16 && n <= 6'd31) gpr[n[3:0]] <= v;
      else case (n)
        6'd49: sp <= v;
        6'd50: lr <= v;
        6'd51: epc <= v;
        6'd52: cause <= v;
        6'd53: evec <= v;
        6'd54: status <= v & STATUS_MASK;
        default: ;
      endcase
    end
  endtask

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      es <= E_RUN;
      sp <= 32'd0; lr <= 32'd0; epc <= 32'd0;
      cause <= CAUSE_RESET; evec <= 32'd0; status <= 32'd0;
      pr <= 7'd0;
      for (i = 0; i < 16; i = i + 1) gpr[i] <= 32'd0;
      halt_code <= 2'd0;
      e_valid <= 1'b0; e_badpc <= 1'b0; e_seen <= 1'b0; pc <= 32'd0; ir <= 32'd0; imm <= 32'd0; e_ferr <= 2'b00;
      q_valid <= 1'b0; q_pc <= 32'd0; q_data <= 64'd0; q_err <= 2'b00;
      f_out <= 1'b0; f_kill <= 1'b0; f_aout <= 32'd0; f_next <= 32'd0;
      m_load <= 1'b0; m_store <= 1'b0; m_rd <= 6'd0; m_op <= 3'd0; m_lo <= 2'd0;
      mem_data <= 32'd0;
    end else begin
      // M：読み出しの返事をレジスタへ（E の書き込みより先に書く。同じレジスタはハザードで起きない）
      if (m_load && d_rvalid) write_reg(m_rd, ld_val);
      if (x_mload) begin m_load <= 1'b1; m_rd <= rd; m_op <= op[2:0]; m_lo <= ls_addr[1:0]; end
      else if (d_rvalid) m_load <= 1'b0;
      if (x_mstore) m_store <= 1'b1;
      else if (d_rvalid) m_store <= 1'b0;

      // E
      es <= x_es;
      if (x_trace) e_seen <= 1'b1;
      if (x_wr) write_reg(x_wi, x_wv);
      if (x_latch) mem_data <= d_rdata;
      if (x_halt) halt_code <= x_hc;
      if (x_exc) begin
        epc <= pc;
        cause <= x_cause;
        status <= (status & ~32'hF) | {28'd0, status[1:0], 2'b00};
      end
      if (x_eret) status <= (status & ~32'h3) | {30'd0, status[3:2]};
      if (x_div) begin
        div_q <= div_signed && a[31] ? -a : a;
        div_b <= div_signed && b[31] ? -b : b;
        div_r <= 33'd0;
        div_cnt <= 6'd32;
        div_negq <= div_signed && (a[31] ^ b[31]);
        div_negr <= div_signed && a[31];
        div_rem <= num >= 6'd7;
      end else if (es == E_DIV && div_cnt != 6'd0) begin
        div_r <= div_ge ? div_try - {1'b0, div_b} : div_try;
        div_q <= {div_q[30:0], div_ge};
        div_cnt <= div_cnt - 6'd1;
      end

      // E に入る命令：飛ぶなら（飛び先がずれていれば、整列違反を起こす印だけの命令）、でなければ q か届いたもの
      if (x_redir) begin
        e_valid <= x_rpc[1:0] != 2'd0;
        e_badpc <= 1'b1; e_seen <= 1'b0; pc <= x_rpc; e_ferr <= 2'b00;
      end else if (x_adv) begin
        e_badpc <= 1'b0; e_seen <= 1'b0;
        if (q_valid) begin
          e_valid <= 1'b1; pc <= q_pc; ir <= q_data[31:0];
          imm <= q_data[1:0] == 2'd0 ? 32'd0 : q_data[63:32]; e_ferr <= q_err;
        end else if (arr) begin
          e_valid <= 1'b1; pc <= f_aout; ir <= i_rdata[31:0];
          imm <= i_rdata[1:0] == 2'd0 ? 32'd0 : i_rdata[63:32]; e_ferr <= i_err;
        end else e_valid <= 1'b0;
      end

      // q
      if (x_redir) q_valid <= 1'b0;
      else if (x_adv ? (q_valid && arr) : (!q_valid && arr)) begin
        q_valid <= 1'b1; q_pc <= f_aout; q_data <= i_rdata; q_err <= i_err;
      end else if (x_adv) q_valid <= 1'b0;

      // F
      if (i_rvalid && f_out) begin f_out <= 1'b0; f_kill <= 1'b0; end
      if (i_req && i_gnt) begin f_out <= 1'b1; f_kill <= 1'b0; f_aout <= i_addr; end
      else if (x_redir && f_out && !i_rvalid) f_kill <= 1'b1;
      f_next <= i_addr;
    end
  end
endmodule
