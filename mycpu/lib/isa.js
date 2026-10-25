// 命令セットの共通定義（isa-spec.md）。アセンブラとシミュレータの両方が使う。
// Node では require、ブラウザでは <script> で読み込む（MyCPU.isa になる）。
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./opcodes.js'));
  else root.MyCPU.isa = factory(root.MyCPU.OPCODES);
})(typeof self !== 'undefined' ? self : this, function (OPCODES) {
  'use strict';

  // width フィールド → 演算の bit 数と命令長（2.2）
  var WIDTH_BITS = [0, 32, 64, 0];
  var INSN_LEN = [4, 8, 12, 0];

  // 特殊レジスタ（3.1）
  var SPECIAL = { pc: 48, sp: 49, lr: 50, epc: 51, cause: 52, evec: 53, status: 54 };
  var SPECIAL_NAME = {};
  Object.keys(SPECIAL).forEach(function (k) { SPECIAL_NAME[SPECIAL[k]] = k; });

  // メモリマップ（4.1）と入出力（仕様の TODO の仮決め。README 参照）
  var MAP = {
    ROM_BASE: 0x00000000, ROM_SIZE: 32 * 1024,
    IO_BASE: 0x00010000, IO_SIZE: 0x8000,
    VRAM_BASE: 0x00018000, VRAM_SIZE: 16 * 1024,
    RAM_BASE: 0x00020000, RAM_SIZE: 32 * 1024,
    SDRAM_BASE: 0x01000000, SDRAM_SIZE: 8 * 1024 * 1024,
  };
  var IO = {
    UART_TX: 0x00, UART_STATUS: 0x04, UART_RX: 0x08,
    TIMER_COUNT: 0x10, TIMER_CMP: 0x14, TIMER_CTRL: 0x18,
    LED: 0x20,
    SD_DATA: 0x30, SD_CTRL: 0x34, SD_STATUS: 0x38,
  };
  var IRQ = { UART_RX: 0, TIMER: 1 };
  var CAUSE = { ILLEGAL: 0, ALIGN: 1, PRIV: 2, SYSCALL: 3, DIVZERO: 4, RESET: 0xFFFF };
  var TEXT = { COLS: 160, ROWS: 45, CELL_W: 8, CELL_H: 16 };

  // レジスタの種類（3.2）
  function regKind(n) {
    if (n === 0) return 'zero';
    if (n < 8) return 'p';
    if (n < 16) return 'reserved';
    if (n < 32) return 'r32';
    if (n < 48) return 'r64';
    if (n === 48) return 'pc';
    if (n <= 54) return 'special';
    return 'reserved';
  }

  function regName(n) {
    if (n >= 1 && n <= 7) return 'p' + n;
    return SPECIAL_NAME[n] || 'r' + n;
  }

  function parseReg(tok) {
    var t = tok.toLowerCase(), m;
    if (Object.prototype.hasOwnProperty.call(SPECIAL, t)) return SPECIAL[t];
    if ((m = /^r(\d+)$/.exec(t)) && +m[1] < 64) return +m[1];
    if ((m = /^p([1-7])$/.exec(t))) return +m[1];
    return null;
  }

  // 各オペランドがどのフィールドに入り、どんなレジスタを許すか。
  //   data … 命令の幅と一致する汎用レジスタ（r0・特殊レジスタも可）
  //   addr … アドレスに使うレジスタ（幅チェックなし。1bit は不可）
  //   p    … 1bit レジスタ（r0 も可）
  //   r32 / r64 … 幅変換命令の決まった幅
  var X_CLASSES = {
    EXT32TO64U: { rd: 'r64', rs1: 'r32' },
    EXT32TO64S: { rd: 'r64', rs1: 'r32' },
    TRUNC64TO32: { rd: 'r32', rs1: 'r64' },
  };
  function operandSpec(row) {
    return row.operands.map(function (name, i) {
      if (name === 'imm') return { name: name, field: 'imm', cls: 'imm' };
      if (name === 'p') {
        // CMP は rd 欄、SEL は即値欄、BR と BTOI は rs1 欄（5.5・5.7・3.3）
        var field = row.form === 'SEL' ? 'imm' : (row.form === 'B' || row.form === 'X') ? 'rs1' : 'rd';
        return { name: name, field: field, cls: 'p' };
      }
      var cls = 'data';
      var x = X_CLASSES[row.mnemonic];
      if (x && x[name]) cls = x[name];
      else if (name === 'rs1' && /^(L|ST|SW|B)$/.test(row.form)) cls = 'addr';
      else if (name === 'rs2' && row.form === 'M') cls = 'addr';
      return { name: name, field: name, cls: cls };
    });
  }

  // レジスタ n が、bit 数 wbits の命令のこの位置に使えるか。使えなければ理由を返す。
  function checkReg(cls, n, wbits, isDest) {
    var k = regKind(n);
    if (k === 'reserved') return 'r' + n + ' は予備レジスタ';
    if (isDest && k === 'pc') return 'PC には書き込めない';
    if (k === 'zero') return null;
    switch (cls) {
      case 'p': return k === 'p' ? null : regName(n) + ' は 1bit レジスタではない';
      case 'addr': return k === 'p' ? '1bit レジスタはアドレスに使えない' : null;
      case 'r32': return k === 'r32' ? null : regName(n) + ' は 32bit レジスタではない';
      case 'r64': return k === 'r64' ? null : regName(n) + ' は 64bit レジスタではない';
      default:
        if (k === 'pc' || k === 'special') return null;
        if (k === 'r32' && wbits === 32) return null;
        if (k === 'r64' && wbits === 64) return null;
        return regName(n) + ' は ' + wbits + 'bit 命令では使えない';
    }
  }

  var byOpcode = new Map();
  var byMnemonic = new Map();
  OPCODES.forEach(function (row) {
    row.spec = operandSpec(row);
    row.wbits = WIDTH_BITS[row.width];
    row.length = INSN_LEN[row.width];
    byOpcode.set(row.opcode, row);
    byMnemonic.set(row.mnemonic.toUpperCase(), row);
  });

  // 命令ヘッダ（2.1）
  function encodeHeader(opcode, rd, rs1, rs2) {
    return (opcode | (rd << 14) | (rs1 << 20) | (rs2 << 26)) >>> 0;
  }
  function decodeHeader(h) {
    return {
      width: h & 3, opcode: h & 0x3fff,
      rd: (h >>> 14) & 63, rs1: (h >>> 20) & 63, rs2: (h >>> 26) & 63,
    };
  }

  function hexImm(v, wbits) {
    var s = BigInt.asUintN(wbits, v);
    return s < 10n ? s.toString() : '0x' + s.toString(16);
  }

  // 逆アセンブル（トレース表示とリスト用）
  function disasm(row, f, imm) {
    var ops = row.spec.map(function (s) {
      if (s.cls === 'imm') return hexImm(imm, row.wbits);
      var n = s.field === 'imm' ? Number(imm & 63n) : f[s.field];
      return regName(n);
    });
    return row.mnemonic + (ops.length ? ' ' + ops.join(', ') : '');
  }

  return {
    OPCODES: OPCODES, WIDTH_BITS: WIDTH_BITS, INSN_LEN: INSN_LEN,
    SPECIAL: SPECIAL, MAP: MAP, IO: IO, IRQ: IRQ, CAUSE: CAUSE, TEXT: TEXT,
    byOpcode: byOpcode, byMnemonic: byMnemonic,
    regKind: regKind, regName: regName, parseReg: parseReg, checkReg: checkReg,
    encodeHeader: encodeHeader, decodeHeader: decodeHeader, disasm: disasm,
  };
});
