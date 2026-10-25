// 自作CPU 32bit 版（isa-spec.md v0.6）
// パイプラインなしで、1 命令を何クロックかに分けて順番に処理する。
//   取り出し（ヘッダ）→ 解読 → 取り出し（即値）→ 実行 →（メモリ）→ 次の命令
// 動作の基準は lib/cpu.js（シミュレータ）。食い違いはテストで見つける。
//
// バス：bus_valid を立てて待ち、bus_ready が 1 クロック立ったら完了。
//   bus_addr は 4 バイト単位（下位 2bit は 0）。bus_wstrb が 0 なら読み出し、それ以外は書き込み。
//   bus_fault はつながっていない番地や ROM への書き込み（このとき CPU は止まる）。
module mycpu_cpu (
  input  wire        clk,
  input  wire        rst,
  output reg  [31:0] bus_addr,
  output reg  [31:0] bus_wdata,
  output reg  [3:0]  bus_wstrb,
  output reg         bus_valid,
  input  wire        bus_ready,
  input  wire [31:0] bus_rdata,
  input  wire        bus_fault,
  input  wire [7:0]  irq,        // 外部割り込み 8 本（レベル）
  output wire        halted,
  output reg  [1:0]  halt_code   // 1 = HLT、2 = 不正命令、3 = バスエラー
);
`include "opcodes.vh"

  localparam [31:0] STATUS_MASK = 32'h0000_FF0F;  // STATUS の実装済み bit（6.2）
  localparam [31:0] CAUSE_RESET = 32'h0000_FFFF;  // 6.3
  localparam [31:0] C_ALIGN = 32'd1, C_PRIV = 32'd2, C_SYSCALL = 32'd3, C_DIVZERO = 32'd4;

  localparam [3:0] S_FETCH = 4'd0, S_FETCH_W = 4'd1, S_DECODE = 4'd2, S_IMM_W = 4'd3,
                   S_EXEC = 4'd4, S_MEM_W = 4'd5, S_STORE_W = 4'd6, S_SWAP_W = 4'd7,
                   S_DIV = 4'd8, S_WFI = 4'd9, S_HALT = 4'd10, S_LOAD = 4'd11;
  reg [3:0] state;
  assign halted = state == S_HALT;

  // ---- レジスタ ----
  reg [31:0] gpr [0:15];   // r16〜r31
  reg [7:1]  pr;           // r1〜r7（1bit）
  reg [31:0] pc, sp, lr, epc, cause, evec, status;
  reg [31:0] ir, imm, mem_data;
  reg        have_mem;     // M 形式で、メモリの値を読み終えた

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
  wire [31:0] ld_shift = mem_data >> {ls_addr[1:0], 3'b000};
  reg  [31:0] ld_val;
  always @* begin
    case (op[2:0])
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

  // ---- 書き込み ----
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

  // 例外・割り込みに入る：EPC・CAUSE を書き、特権と割り込み許可を退避して EVEC へ
  task enter(input [31:0] c, input [31:0] ret);
    begin
      epc <= ret;
      cause <= c;
      status <= (status & ~32'hF) | {28'd0, status[1:0], 2'b00};
      pc <= evec;
      state <= S_FETCH;
    end
  endtask

  task halt(input [1:0] code);
    begin
      halt_code <= code;
      state <= S_HALT;
    end
  endtask

  task bus_read(input [31:0] addr, input [3:0] next);
    begin
      bus_addr <= {addr[31:2], 2'b00};
      bus_wstrb <= 4'd0;
      bus_valid <= 1'b1;
      state <= next;
    end
  endtask

  task finish;   // 次の命令へ
    begin
      pc <= next_pc;
      state <= S_FETCH;
    end
  endtask

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      state <= S_FETCH;
      pc <= 32'd0; sp <= 32'd0; lr <= 32'd0; epc <= 32'd0;
      cause <= CAUSE_RESET; evec <= 32'd0; status <= 32'd0;
      pr <= 7'd0;
      for (i = 0; i < 16; i = i + 1) gpr[i] <= 32'd0;
      bus_valid <= 1'b0; bus_wstrb <= 4'd0; bus_addr <= 32'd0; bus_wdata <= 32'd0;
      halt_code <= 2'd0;
      have_mem <= 1'b0;
    end else begin
      case (state)
        S_FETCH: begin
          have_mem <= 1'b0;
          if (status[1] && irq_m != 8'd0) enter(32'h8000_0000 | irq_n, pc);
          else if (pc[1:0] != 2'd0) enter(C_ALIGN, pc);
          else bus_read(pc, S_FETCH_W);
        end
        S_FETCH_W: if (bus_ready) begin
          bus_valid <= 1'b0;
          if (bus_fault) halt(2'd3);
          else begin ir <= bus_rdata; imm <= 32'd0; state <= S_DECODE; end
        end
        S_DECODE: begin
          if (!insn_ok) halt(2'd2);
          else if (width == 2'd1) bus_read(pc + 32'd4, S_IMM_W);
          else state <= S_EXEC;
        end
        S_IMM_W: if (bus_ready) begin
          bus_valid <= 1'b0;
          if (bus_fault) halt(2'd3);
          else begin imm <= bus_rdata; state <= S_EXEC; end
        end
        S_EXEC: begin
          if (priv_dest && user) enter(C_PRIV, pc);
          else case (grp)
            4'd0: begin  // システム（5.2）
              if (user && op != 8'h01 && op != 8'h03) enter(C_PRIV, pc);
              else case (op)
                8'h00: halt(2'd1);
                8'h01: finish;
                8'h02: begin
                  status <= (status & ~32'h3) | {30'd0, status[3:2]};
                  pc <= epc;
                  state <= S_FETCH;
                end
                8'h03: enter(C_SYSCALL, pc);
                default: begin pc <= next_pc; state <= S_WFI; end   // WFI
              endcase
            end
            4'd1, 4'd2, 4'd3: begin
              if (is_mform && !have_mem) begin
                if (m_addr[1:0] != 2'd0) enter(C_ALIGN, pc);
                else bus_read(m_addr, S_MEM_W);
              end else if (is_sel && imm[5:0] > 6'd7) halt(2'd2);
              else if (is_div) begin
                if (b == 32'd0) enter(C_DIVZERO, pc);
                else begin
                  div_q <= div_signed && a[31] ? -a : a;
                  div_b <= div_signed && b[31] ? -b : b;
                  div_r <= 33'd0;
                  div_cnt <= 6'd32;
                  div_negq <= div_signed && (a[31] ^ b[31]);
                  div_negr <= div_signed && a[31];
                  div_rem <= num >= 6'd7;
                  state <= S_DIV;
                end
              end else begin
                write_reg(rd, alu);
                finish;
              end
            end
            4'd4: begin  // ロード・ストア（5.6）
              if (ls_misaligned) enter(C_ALIGN, pc);
              else if (is_store) begin
                bus_addr <= {ls_addr[31:2], 2'b00};
                bus_wdata <= st_data;
                bus_wstrb <= st_strb;
                bus_valid <= 1'b1;
                state <= S_STORE_W;
              end else bus_read(ls_addr, S_MEM_W);
            end
            4'd5: begin  // 分岐・呼び出し（5.7）
              state <= S_FETCH;
              case (op)
                8'h00: pc <= imm;
                8'h01: pc <= pr[rs1[2:0]] && rs1 != 6'd0 ? imm : next_pc;
                8'h02: begin lr <= next_pc; pc <= imm; end
                8'h03: pc <= lr;
                8'h04: pc <= a;
                default: begin lr <= next_pc; pc <= a; end  // CALLR（飛び先は書き換え前の値）
              endcase
            end
            default: begin  // 幅変換（5.8）。32bit CPU で使えるのは TRUNC64TO32（r0 だけ）と BTOI32
              write_reg(rd, op == 8'h03 ? a : 32'd0);
              finish;
            end
          endcase
        end
        S_MEM_W: if (bus_ready) begin
          bus_valid <= 1'b0;
          if (bus_fault) halt(2'd3);
          else if (is_swap) begin
            mem_data <= bus_rdata;
            bus_wdata <= bR;
            bus_wstrb <= 4'b1111;
            bus_valid <= 1'b1;
            state <= S_SWAP_W;
          end else if (is_load) begin
            mem_data <= bus_rdata;
            state <= S_LOAD;
          end else begin
            mem_data <= bus_rdata;
            have_mem <= 1'b1;
            state <= S_EXEC;      // M 形式：読んだ値で演算する
          end
        end
        S_LOAD: begin
          write_reg(rd, ld_val);
          finish;
        end
        S_STORE_W: if (bus_ready) begin
          bus_valid <= 1'b0;
          bus_wstrb <= 4'd0;
          if (bus_fault) halt(2'd3);
          else finish;
        end
        S_SWAP_W: if (bus_ready) begin
          bus_valid <= 1'b0;
          bus_wstrb <= 4'd0;
          if (bus_fault) halt(2'd3);
          else begin write_reg(rd, mem_data); finish; end
        end
        S_DIV: begin
          if (div_cnt != 6'd0) begin
            div_r <= div_ge ? div_try - {1'b0, div_b} : div_try;
            div_q <= {div_q[30:0], div_ge};
            div_cnt <= div_cnt - 6'd1;
          end else begin
            write_reg(rd, div_rem ? div_rres : div_qres);
            finish;
          end
        end
        S_WFI: if (irq_m != 8'd0) state <= S_FETCH;
        default: ;  // S_HALT
      endcase
    end
  end
endmodule
