// 自動生成（tools/gen.js が opcodes.csv から作る）。手で編集しない。
// 14bit オペコード = {op[7:0], group[3:0], width[1:0]}
localparam [13:0] OP_HLT             = 14'h0000; // 停止（命令全体が0）
localparam [13:0] OP_NOP             = 14'h0040; // 何もしない
localparam [13:0] OP_ERET            = 14'h0080; // EPCへ戻りSTATUSを例外前に戻す
localparam [13:0] OP_SYSCALL         = 14'h00C0; // SYSCALL例外を起こす
localparam [13:0] OP_WFI             = 14'h0100; // 割り込みが来るまで待つ
localparam [13:0] OP_ADDR32          = 14'h0005; // rd ← rs1 + rs2
localparam [13:0] OP_ADDR64          = 14'h0006; // rd ← rs1 + rs2
localparam [13:0] OP_ADDI32          = 14'h0045; // rd ← rs1 + imm
localparam [13:0] OP_ADDI64          = 14'h0046; // rd ← rs1 + imm
localparam [13:0] OP_ADD32           = 14'h0085; // rd ← rs1 + [rs2+imm]
localparam [13:0] OP_ADD64           = 14'h0086; // rd ← rs1 + [rs2+imm]
localparam [13:0] OP_SUBR32          = 14'h0105; // rd ← rs1 - rs2
localparam [13:0] OP_SUBR64          = 14'h0106; // rd ← rs1 - rs2
localparam [13:0] OP_SUB32           = 14'h0185; // rd ← rs1 - [rs2+imm]
localparam [13:0] OP_SUB64           = 14'h0186; // rd ← rs1 - [rs2+imm]
localparam [13:0] OP_MULR32          = 14'h0205; // rd ← rs1 × rs2（下位）
localparam [13:0] OP_MULR64          = 14'h0206; // rd ← rs1 × rs2（下位）
localparam [13:0] OP_MULI32          = 14'h0245; // rd ← rs1 × imm（下位）
localparam [13:0] OP_MULI64          = 14'h0246; // rd ← rs1 × imm（下位）
localparam [13:0] OP_MUL32           = 14'h0285; // rd ← rs1 × [rs2+imm]（下位）
localparam [13:0] OP_MUL64           = 14'h0286; // rd ← rs1 × [rs2+imm]（下位）
localparam [13:0] OP_MULHR32         = 14'h0305; // rd ← rs1 × rs2 の上位（符号付き）
localparam [13:0] OP_MULHR64         = 14'h0306; // rd ← rs1 × rs2 の上位（符号付き）
localparam [13:0] OP_MULHI32         = 14'h0345; // rd ← rs1 × imm の上位（符号付き）
localparam [13:0] OP_MULHI64         = 14'h0346; // rd ← rs1 × imm の上位（符号付き）
localparam [13:0] OP_MULH32          = 14'h0385; // rd ← rs1 × [rs2+imm] の上位（符号付き）
localparam [13:0] OP_MULH64          = 14'h0386; // rd ← rs1 × [rs2+imm] の上位（符号付き）
localparam [13:0] OP_MULHUR32        = 14'h0405; // rd ← rs1 × rs2 の上位（符号なし）
localparam [13:0] OP_MULHUR64        = 14'h0406; // rd ← rs1 × rs2 の上位（符号なし）
localparam [13:0] OP_MULHUI32        = 14'h0445; // rd ← rs1 × imm の上位（符号なし）
localparam [13:0] OP_MULHUI64        = 14'h0446; // rd ← rs1 × imm の上位（符号なし）
localparam [13:0] OP_MULHU32         = 14'h0485; // rd ← rs1 × [rs2+imm] の上位（符号なし）
localparam [13:0] OP_MULHU64         = 14'h0486; // rd ← rs1 × [rs2+imm] の上位（符号なし）
localparam [13:0] OP_DIVR32          = 14'h0505; // rd ← rs1 ÷ rs2（符号付き）
localparam [13:0] OP_DIVR64          = 14'h0506; // rd ← rs1 ÷ rs2（符号付き）
localparam [13:0] OP_DIVI32          = 14'h0545; // rd ← rs1 ÷ imm（符号付き）
localparam [13:0] OP_DIVI64          = 14'h0546; // rd ← rs1 ÷ imm（符号付き）
localparam [13:0] OP_DIV32           = 14'h0585; // rd ← rs1 ÷ [rs2+imm]（符号付き）
localparam [13:0] OP_DIV64           = 14'h0586; // rd ← rs1 ÷ [rs2+imm]（符号付き）
localparam [13:0] OP_DIVUR32         = 14'h0605; // rd ← rs1 ÷ rs2（符号なし）
localparam [13:0] OP_DIVUR64         = 14'h0606; // rd ← rs1 ÷ rs2（符号なし）
localparam [13:0] OP_DIVUI32         = 14'h0645; // rd ← rs1 ÷ imm（符号なし）
localparam [13:0] OP_DIVUI64         = 14'h0646; // rd ← rs1 ÷ imm（符号なし）
localparam [13:0] OP_DIVU32          = 14'h0685; // rd ← rs1 ÷ [rs2+imm]（符号なし）
localparam [13:0] OP_DIVU64          = 14'h0686; // rd ← rs1 ÷ [rs2+imm]（符号なし）
localparam [13:0] OP_REMR32          = 14'h0705; // rd ← rs1 mod rs2（符号付き）
localparam [13:0] OP_REMR64          = 14'h0706; // rd ← rs1 mod rs2（符号付き）
localparam [13:0] OP_REMI32          = 14'h0745; // rd ← rs1 mod imm（符号付き）
localparam [13:0] OP_REMI64          = 14'h0746; // rd ← rs1 mod imm（符号付き）
localparam [13:0] OP_REM32           = 14'h0785; // rd ← rs1 mod [rs2+imm]（符号付き）
localparam [13:0] OP_REM64           = 14'h0786; // rd ← rs1 mod [rs2+imm]（符号付き）
localparam [13:0] OP_REMUR32         = 14'h0805; // rd ← rs1 mod rs2（符号なし）
localparam [13:0] OP_REMUR64         = 14'h0806; // rd ← rs1 mod rs2（符号なし）
localparam [13:0] OP_REMUI32         = 14'h0845; // rd ← rs1 mod imm（符号なし）
localparam [13:0] OP_REMUI64         = 14'h0846; // rd ← rs1 mod imm（符号なし）
localparam [13:0] OP_REMU32          = 14'h0885; // rd ← rs1 mod [rs2+imm]（符号なし）
localparam [13:0] OP_REMU64          = 14'h0886; // rd ← rs1 mod [rs2+imm]（符号なし）
localparam [13:0] OP_ANDR32          = 14'h0009; // rd ← rs1 AND rs2
localparam [13:0] OP_ANDR64          = 14'h000A; // rd ← rs1 AND rs2
localparam [13:0] OP_ANDI32          = 14'h0049; // rd ← rs1 AND imm
localparam [13:0] OP_ANDI64          = 14'h004A; // rd ← rs1 AND imm
localparam [13:0] OP_AND32           = 14'h0089; // rd ← rs1 AND [rs2+imm]
localparam [13:0] OP_AND64           = 14'h008A; // rd ← rs1 AND [rs2+imm]
localparam [13:0] OP_ORR32           = 14'h0109; // rd ← rs1 OR rs2
localparam [13:0] OP_ORR64           = 14'h010A; // rd ← rs1 OR rs2
localparam [13:0] OP_ORI32           = 14'h0149; // rd ← rs1 OR imm
localparam [13:0] OP_ORI64           = 14'h014A; // rd ← rs1 OR imm
localparam [13:0] OP_OR32            = 14'h0189; // rd ← rs1 OR [rs2+imm]
localparam [13:0] OP_OR64            = 14'h018A; // rd ← rs1 OR [rs2+imm]
localparam [13:0] OP_XORR32          = 14'h0209; // rd ← rs1 XOR rs2
localparam [13:0] OP_XORR64          = 14'h020A; // rd ← rs1 XOR rs2
localparam [13:0] OP_XORI32          = 14'h0249; // rd ← rs1 XOR imm
localparam [13:0] OP_XORI64          = 14'h024A; // rd ← rs1 XOR imm
localparam [13:0] OP_XOR32           = 14'h0289; // rd ← rs1 XOR [rs2+imm]
localparam [13:0] OP_XOR64           = 14'h028A; // rd ← rs1 XOR [rs2+imm]
localparam [13:0] OP_SHLR32          = 14'h0309; // rd ← rs1 << rs2
localparam [13:0] OP_SHLR64          = 14'h030A; // rd ← rs1 << rs2
localparam [13:0] OP_SHLI32          = 14'h0349; // rd ← rs1 << imm
localparam [13:0] OP_SHLI64          = 14'h034A; // rd ← rs1 << imm
localparam [13:0] OP_SHL32           = 14'h0389; // rd ← rs1 << [rs2+imm]
localparam [13:0] OP_SHL64           = 14'h038A; // rd ← rs1 << [rs2+imm]
localparam [13:0] OP_SHRR32          = 14'h0409; // rd ← rs1 >> rs2（論理）
localparam [13:0] OP_SHRR64          = 14'h040A; // rd ← rs1 >> rs2（論理）
localparam [13:0] OP_SHRI32          = 14'h0449; // rd ← rs1 >> imm（論理）
localparam [13:0] OP_SHRI64          = 14'h044A; // rd ← rs1 >> imm（論理）
localparam [13:0] OP_SHR32           = 14'h0489; // rd ← rs1 >> [rs2+imm]（論理）
localparam [13:0] OP_SHR64           = 14'h048A; // rd ← rs1 >> [rs2+imm]（論理）
localparam [13:0] OP_SARR32          = 14'h0509; // rd ← rs1 >> rs2（算術）
localparam [13:0] OP_SARR64          = 14'h050A; // rd ← rs1 >> rs2（算術）
localparam [13:0] OP_SARI32          = 14'h0549; // rd ← rs1 >> imm（算術）
localparam [13:0] OP_SARI64          = 14'h054A; // rd ← rs1 >> imm（算術）
localparam [13:0] OP_SAR32           = 14'h0589; // rd ← rs1 >> [rs2+imm]（算術）
localparam [13:0] OP_SAR64           = 14'h058A; // rd ← rs1 >> [rs2+imm]（算術）
localparam [13:0] OP_CLZ32           = 14'h0609; // rd ← rs1 の先頭の0の個数
localparam [13:0] OP_CLZ64           = 14'h060A; // rd ← rs1 の先頭の0の個数
localparam [13:0] OP_POPCNT32        = 14'h0709; // rd ← rs1 の1の個数
localparam [13:0] OP_POPCNT64        = 14'h070A; // rd ← rs1 の1の個数
localparam [13:0] OP_CMPEQR32        = 14'h000D; // p ← (rs1 == rs2)
localparam [13:0] OP_CMPEQR64        = 14'h000E; // p ← (rs1 == rs2)
localparam [13:0] OP_CMPEQI32        = 14'h004D; // p ← (rs1 == imm)
localparam [13:0] OP_CMPEQI64        = 14'h004E; // p ← (rs1 == imm)
localparam [13:0] OP_CMPEQ32         = 14'h008D; // p ← (rs1 == [rs2+imm])
localparam [13:0] OP_CMPEQ64         = 14'h008E; // p ← (rs1 == [rs2+imm])
localparam [13:0] OP_CMPNER32        = 14'h010D; // p ← (rs1 != rs2)
localparam [13:0] OP_CMPNER64        = 14'h010E; // p ← (rs1 != rs2)
localparam [13:0] OP_CMPNEI32        = 14'h014D; // p ← (rs1 != imm)
localparam [13:0] OP_CMPNEI64        = 14'h014E; // p ← (rs1 != imm)
localparam [13:0] OP_CMPNE32         = 14'h018D; // p ← (rs1 != [rs2+imm])
localparam [13:0] OP_CMPNE64         = 14'h018E; // p ← (rs1 != [rs2+imm])
localparam [13:0] OP_CMPLTR32        = 14'h020D; // p ← (rs1 < rs2)（符号付き）
localparam [13:0] OP_CMPLTR64        = 14'h020E; // p ← (rs1 < rs2)（符号付き）
localparam [13:0] OP_CMPLTI32        = 14'h024D; // p ← (rs1 < imm)（符号付き）
localparam [13:0] OP_CMPLTI64        = 14'h024E; // p ← (rs1 < imm)（符号付き）
localparam [13:0] OP_CMPLT32         = 14'h028D; // p ← (rs1 < [rs2+imm])（符号付き）
localparam [13:0] OP_CMPLT64         = 14'h028E; // p ← (rs1 < [rs2+imm])（符号付き）
localparam [13:0] OP_CMPLTUR32       = 14'h030D; // p ← (rs1 < rs2)（符号なし）
localparam [13:0] OP_CMPLTUR64       = 14'h030E; // p ← (rs1 < rs2)（符号なし）
localparam [13:0] OP_CMPLTUI32       = 14'h034D; // p ← (rs1 < imm)（符号なし）
localparam [13:0] OP_CMPLTUI64       = 14'h034E; // p ← (rs1 < imm)（符号なし）
localparam [13:0] OP_CMPLTU32        = 14'h038D; // p ← (rs1 < [rs2+imm])（符号なし）
localparam [13:0] OP_CMPLTU64        = 14'h038E; // p ← (rs1 < [rs2+imm])（符号なし）
localparam [13:0] OP_CMPGER32        = 14'h040D; // p ← (rs1 >= rs2)（符号付き）
localparam [13:0] OP_CMPGER64        = 14'h040E; // p ← (rs1 >= rs2)（符号付き）
localparam [13:0] OP_CMPGEI32        = 14'h044D; // p ← (rs1 >= imm)（符号付き）
localparam [13:0] OP_CMPGEI64        = 14'h044E; // p ← (rs1 >= imm)（符号付き）
localparam [13:0] OP_CMPGE32         = 14'h048D; // p ← (rs1 >= [rs2+imm])（符号付き）
localparam [13:0] OP_CMPGE64         = 14'h048E; // p ← (rs1 >= [rs2+imm])（符号付き）
localparam [13:0] OP_CMPGEUR32       = 14'h050D; // p ← (rs1 >= rs2)（符号なし）
localparam [13:0] OP_CMPGEUR64       = 14'h050E; // p ← (rs1 >= rs2)（符号なし）
localparam [13:0] OP_CMPGEUI32       = 14'h054D; // p ← (rs1 >= imm)（符号なし）
localparam [13:0] OP_CMPGEUI64       = 14'h054E; // p ← (rs1 >= imm)（符号なし）
localparam [13:0] OP_CMPGEU32        = 14'h058D; // p ← (rs1 >= [rs2+imm])（符号なし）
localparam [13:0] OP_CMPGEU64        = 14'h058E; // p ← (rs1 >= [rs2+imm])（符号なし）
localparam [13:0] OP_SEL32           = 14'h060D; // rd ← p ? rs1 : rs2（p の番号は即値の下位6bit）
localparam [13:0] OP_SEL64           = 14'h060E; // rd ← p ? rs1 : rs2（p の番号は即値の下位6bit）
localparam [13:0] OP_LOAD8U_32       = 14'h0011; // rd ← [rs1+imm]（8bit・ゼロ拡張）
localparam [13:0] OP_LOAD8U_64       = 14'h0012; // rd ← [rs1+imm]（8bit・ゼロ拡張）
localparam [13:0] OP_LOAD8S_32       = 14'h0051; // rd ← [rs1+imm]（8bit・符号拡張）
localparam [13:0] OP_LOAD8S_64       = 14'h0052; // rd ← [rs1+imm]（8bit・符号拡張）
localparam [13:0] OP_LOAD16U_32      = 14'h0091; // rd ← [rs1+imm]（16bit・ゼロ拡張）
localparam [13:0] OP_LOAD16U_64      = 14'h0092; // rd ← [rs1+imm]（16bit・ゼロ拡張）
localparam [13:0] OP_LOAD16S_32      = 14'h00D1; // rd ← [rs1+imm]（16bit・符号拡張）
localparam [13:0] OP_LOAD16S_64      = 14'h00D2; // rd ← [rs1+imm]（16bit・符号拡張）
localparam [13:0] OP_LOAD32_32       = 14'h0111; // rd ← [rs1+imm]（32bit）
localparam [13:0] OP_LOAD32U_64      = 14'h0112; // rd ← [rs1+imm]（32bit・ゼロ拡張）
localparam [13:0] OP_LOAD32S_64      = 14'h0152; // rd ← [rs1+imm]（32bit・符号拡張）
localparam [13:0] OP_LOAD64_64       = 14'h0192; // rd ← [rs1+imm]（64bit）
localparam [13:0] OP_STORE8_32       = 14'h0411; // [rs1+imm] ← rs2 の下位8bit
localparam [13:0] OP_STORE8_64       = 14'h0412; // [rs1+imm] ← rs2 の下位8bit
localparam [13:0] OP_STORE16_32      = 14'h0451; // [rs1+imm] ← rs2 の下位16bit
localparam [13:0] OP_STORE16_64      = 14'h0452; // [rs1+imm] ← rs2 の下位16bit
localparam [13:0] OP_STORE32_32      = 14'h0491; // [rs1+imm] ← rs2 の下位32bit
localparam [13:0] OP_STORE32_64      = 14'h0492; // [rs1+imm] ← rs2 の下位32bit
localparam [13:0] OP_STORE64_64      = 14'h04D2; // [rs1+imm] ← rs2（64bit）
localparam [13:0] OP_SWAP32          = 14'h0811; // 不可分に rd ← [rs1+imm]、[rs1+imm] ← rs2
localparam [13:0] OP_SWAP64          = 14'h0812; // 不可分に rd ← [rs1+imm]、[rs1+imm] ← rs2
localparam [13:0] OP_JMP32           = 14'h0015; // imm へ
localparam [13:0] OP_JMP64           = 14'h0016; // imm へ
localparam [13:0] OP_BR32            = 14'h0055; // p が1なら imm へ（p は rs1 欄）
localparam [13:0] OP_BR64            = 14'h0056; // p が1なら imm へ（p は rs1 欄）
localparam [13:0] OP_CALL32          = 14'h0095; // LR ← 次の命令、imm へ
localparam [13:0] OP_CALL64          = 14'h0096; // LR ← 次の命令、imm へ
localparam [13:0] OP_RET32           = 14'h00D5; // LR へ
localparam [13:0] OP_RET64           = 14'h00D6; // LR へ
localparam [13:0] OP_JMPR32          = 14'h0115; // rs1 の番地へ
localparam [13:0] OP_JMPR64          = 14'h0116; // rs1 の番地へ
localparam [13:0] OP_CALLR32         = 14'h0155; // LR ← 次の命令、rs1 の番地へ
localparam [13:0] OP_CALLR64         = 14'h0156; // LR ← 次の命令、rs1 の番地へ
localparam [13:0] OP_EXT32TO64U      = 14'h001A; // 64bit rd ← 32bit rs1（ゼロ拡張）
localparam [13:0] OP_EXT32TO64S      = 14'h005A; // 64bit rd ← 32bit rs1（符号拡張）
localparam [13:0] OP_TRUNC64TO32     = 14'h0099; // 32bit rd ← 64bit rs1 の下位
localparam [13:0] OP_BTOI32          = 14'h00D9; // rd ← p（0か1）
localparam [13:0] OP_BTOI64          = 14'h00DA; // rd ← p（0か1）

// 32bit CPU で使える命令（width 00 / 01）
function automatic op_valid32(input [13:0] o);
  begin
    case (o)
      OP_HLT, OP_NOP, OP_ERET, OP_SYSCALL, OP_WFI, OP_ADDR32,
      OP_ADDI32, OP_ADD32, OP_SUBR32, OP_SUB32, OP_MULR32, OP_MULI32,
      OP_MUL32, OP_MULHR32, OP_MULHI32, OP_MULH32, OP_MULHUR32, OP_MULHUI32,
      OP_MULHU32, OP_DIVR32, OP_DIVI32, OP_DIV32, OP_DIVUR32, OP_DIVUI32,
      OP_DIVU32, OP_REMR32, OP_REMI32, OP_REM32, OP_REMUR32, OP_REMUI32,
      OP_REMU32, OP_ANDR32, OP_ANDI32, OP_AND32, OP_ORR32, OP_ORI32,
      OP_OR32, OP_XORR32, OP_XORI32, OP_XOR32, OP_SHLR32, OP_SHLI32,
      OP_SHL32, OP_SHRR32, OP_SHRI32, OP_SHR32, OP_SARR32, OP_SARI32,
      OP_SAR32, OP_CLZ32, OP_POPCNT32, OP_CMPEQR32, OP_CMPEQI32, OP_CMPEQ32,
      OP_CMPNER32, OP_CMPNEI32, OP_CMPNE32, OP_CMPLTR32, OP_CMPLTI32, OP_CMPLT32,
      OP_CMPLTUR32, OP_CMPLTUI32, OP_CMPLTU32, OP_CMPGER32, OP_CMPGEI32, OP_CMPGE32,
      OP_CMPGEUR32, OP_CMPGEUI32, OP_CMPGEU32, OP_SEL32, OP_LOAD8U_32, OP_LOAD8S_32,
      OP_LOAD16U_32, OP_LOAD16S_32, OP_LOAD32_32, OP_STORE8_32, OP_STORE16_32, OP_STORE32_32,
      OP_SWAP32, OP_JMP32, OP_BR32, OP_CALL32, OP_RET32, OP_JMPR32,
      OP_CALLR32, OP_TRUNC64TO32, OP_BTOI32:
        op_valid32 = 1'b1;
      default: op_valid32 = 1'b0;
    endcase
  end
endfunction

// 64bit CPU で使える命令（width 00 / 01 / 10）
function automatic op_valid64(input [13:0] o);
  begin
    case (o)
      OP_HLT, OP_NOP, OP_ERET, OP_SYSCALL, OP_WFI, OP_ADDR32,
      OP_ADDR64, OP_ADDI32, OP_ADDI64, OP_ADD32, OP_ADD64, OP_SUBR32,
      OP_SUBR64, OP_SUB32, OP_SUB64, OP_MULR32, OP_MULR64, OP_MULI32,
      OP_MULI64, OP_MUL32, OP_MUL64, OP_MULHR32, OP_MULHR64, OP_MULHI32,
      OP_MULHI64, OP_MULH32, OP_MULH64, OP_MULHUR32, OP_MULHUR64, OP_MULHUI32,
      OP_MULHUI64, OP_MULHU32, OP_MULHU64, OP_DIVR32, OP_DIVR64, OP_DIVI32,
      OP_DIVI64, OP_DIV32, OP_DIV64, OP_DIVUR32, OP_DIVUR64, OP_DIVUI32,
      OP_DIVUI64, OP_DIVU32, OP_DIVU64, OP_REMR32, OP_REMR64, OP_REMI32,
      OP_REMI64, OP_REM32, OP_REM64, OP_REMUR32, OP_REMUR64, OP_REMUI32,
      OP_REMUI64, OP_REMU32, OP_REMU64, OP_ANDR32, OP_ANDR64, OP_ANDI32,
      OP_ANDI64, OP_AND32, OP_AND64, OP_ORR32, OP_ORR64, OP_ORI32,
      OP_ORI64, OP_OR32, OP_OR64, OP_XORR32, OP_XORR64, OP_XORI32,
      OP_XORI64, OP_XOR32, OP_XOR64, OP_SHLR32, OP_SHLR64, OP_SHLI32,
      OP_SHLI64, OP_SHL32, OP_SHL64, OP_SHRR32, OP_SHRR64, OP_SHRI32,
      OP_SHRI64, OP_SHR32, OP_SHR64, OP_SARR32, OP_SARR64, OP_SARI32,
      OP_SARI64, OP_SAR32, OP_SAR64, OP_CLZ32, OP_CLZ64, OP_POPCNT32,
      OP_POPCNT64, OP_CMPEQR32, OP_CMPEQR64, OP_CMPEQI32, OP_CMPEQI64, OP_CMPEQ32,
      OP_CMPEQ64, OP_CMPNER32, OP_CMPNER64, OP_CMPNEI32, OP_CMPNEI64, OP_CMPNE32,
      OP_CMPNE64, OP_CMPLTR32, OP_CMPLTR64, OP_CMPLTI32, OP_CMPLTI64, OP_CMPLT32,
      OP_CMPLT64, OP_CMPLTUR32, OP_CMPLTUR64, OP_CMPLTUI32, OP_CMPLTUI64, OP_CMPLTU32,
      OP_CMPLTU64, OP_CMPGER32, OP_CMPGER64, OP_CMPGEI32, OP_CMPGEI64, OP_CMPGE32,
      OP_CMPGE64, OP_CMPGEUR32, OP_CMPGEUR64, OP_CMPGEUI32, OP_CMPGEUI64, OP_CMPGEU32,
      OP_CMPGEU64, OP_SEL32, OP_SEL64, OP_LOAD8U_32, OP_LOAD8U_64, OP_LOAD8S_32,
      OP_LOAD8S_64, OP_LOAD16U_32, OP_LOAD16U_64, OP_LOAD16S_32, OP_LOAD16S_64, OP_LOAD32_32,
      OP_LOAD32U_64, OP_LOAD32S_64, OP_LOAD64_64, OP_STORE8_32, OP_STORE8_64, OP_STORE16_32,
      OP_STORE16_64, OP_STORE32_32, OP_STORE32_64, OP_STORE64_64, OP_SWAP32, OP_SWAP64,
      OP_JMP32, OP_JMP64, OP_BR32, OP_BR64, OP_CALL32, OP_CALL64,
      OP_RET32, OP_RET64, OP_JMPR32, OP_JMPR64, OP_CALLR32, OP_CALLR64,
      OP_EXT32TO64U, OP_EXT32TO64S, OP_TRUNC64TO32, OP_BTOI32, OP_BTOI64:
        op_valid64 = 1'b1;
      default: op_valid64 = 1'b0;
    endcase
  end
endfunction
