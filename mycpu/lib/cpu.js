// CPU とバス・入出力のシミュレータ（isa-spec.md の動作をそのまま書いたもの）。
// Verilog の答え合わせ役も兼ねるので、仕様にない部分の仮決めは Verilog と同じにしてある（README 参照）。
//
//   var cpu = new CPU({ xlen: 32, onTx: function (byte) {...} });
//   cpu.load(image); cpu.run(100000);
//   cpu.halted … 止まった理由 { kind: 'hlt' | 'illegal' | 'fault', message }
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./isa.js'));
  else root.MyCPU.CPU = factory(root.MyCPU.isa);
})(typeof self !== 'undefined' ? self : this, function (isa) {
  'use strict';

  var MAP = isa.MAP, IO = isa.IO, CAUSE = isa.CAUSE;
  var M32 = 0xffffffffn, M64 = 0xffffffffffffffffn;
  function mask(w) { return w === 32 ? M32 : M64; }
  var STATUS_BITS = 0xff0fn; // STATUS の実装済み bit（6.2）。ほかは 0 を読む
  var LOAD_SIZE = [1, 1, 2, 2, 4, 4, 8];
  var STORE_SIZE = [1, 2, 4, 8];

  // 例外（6 章）。step の中で投げて、step の外側で受ける
  function Trap(code) { this.code = code; }
  // 停止（HLT・不正命令・つながっていない番地）
  function Halt(kind, message) { this.kind = kind; this.message = message; }

  function CPU(opts) {
    opts = opts || {};
    this.xlen = opts.xlen === 64 ? 64 : 32;
    this.XM = mask(this.xlen);
    this.onTx = opts.onTx || function () {};
    this.onLed = opts.onLed || function () {};
    // 時間（µs）。既定は 1 命令 = 1µs で決定的。ブラウザでは実時間を渡す
    this.clock = opts.clock || null;
    this.trace = opts.trace || null;
    this.rom = new Uint8Array(MAP.ROM_SIZE);
    this.vram = new Uint8Array(MAP.VRAM_SIZE);
    this.ram = new Uint8Array(MAP.RAM_SIZE);
    this.sdram = null; // 使ったときに確保（8MB）
    this.vramDirty = new Uint8Array(isa.TEXT.COLS * isa.TEXT.ROWS);
    this.vramChanged = false;
    this.decodeCache = new Map();
    this.reset();
  }

  CPU.prototype.reset = function () {
    this.p = [false, false, false, false, false, false, false, false];
    this.r32 = new Array(16).fill(0n);
    this.r64 = new Array(16).fill(0n);
    // 特殊レジスタ r48〜r54（r48 = PC は this.pc で持つ）
    this.pc = 0n;
    this.sp = 0n; this.lr = 0n; this.epc = 0n;
    this.cause = BigInt(CAUSE.RESET); // 6.3
    this.evec = 0n; // 6.1
    this.status = 0n; // カーネルモード・割り込み禁止
    this.rx = [];
    this.timerBase = 0; this.timerCmp = 0; this.timerEn = false;
    this.led = 0;
    this.steps = 0;
    this.ticks = 0;
    this.wfi = false;
    this.halted = null;
  };

  // プログラムを番地 0 から置く（ROM を超えた分はその番地のメモリへ）。
  // .org で飛ばしたすき間（メモリのない番地の 0）は読み飛ばす。戻り値は「番地 0 に命令があるか」
  CPU.prototype.load = function (image, base) {
    base = base || 0;
    for (var i = 0; i < image.length; i++) {
      var r = this.region(base + i, 1);
      if (!r || !r.mem) {
        if (image[i] === 0) continue;
        throw new Error('0x' + (base + i).toString(16) + ' にはメモリがないので、プログラムを置けない');
      }
      r.mem[r.off] = image[i];
    }
    this.vramDirty.fill(1);
    this.vramChanged = true;
    return (this.rom[0] | this.rom[1] | this.rom[2] | this.rom[3]) !== 0;
  };

  // 番地 0 に何もないときの説明（リセット後は番地 0 から実行するので、すぐ HLT で止まる）
  CPU.NO_RESET_CODE = '番地 0（リセット後に実行を始める場所）に何もないので、すぐ HLT で止まる。' +
    '.org 0x20000 で書いたプログラムは、mydos.asm の BIOS から UART 起動で読み込んで使う（tools/mkboot.js）。';

  CPU.prototype.pushRx = function (bytes) {
    for (var i = 0; i < bytes.length; i++) this.rx.push(bytes[i] & 0xff);
  };

  // ---- 時間とタイマー（仮決め：µs で数える 32bit カウンタ） ----

  CPU.prototype.now = function () {
    return this.clock ? this.clock() : this.ticks;
  };
  CPU.prototype.timerCount = function () {
    return (this.now() - this.timerBase) >>> 0;
  };
  CPU.prototype.timerPending = function () {
    return this.timerEn && ((this.timerCount() - this.timerCmp) | 0) >= 0;
  };
  CPU.prototype.irqPending = function () {
    var bits = 0;
    if (this.rx.length) bits |= 1 << isa.IRQ.UART_RX;
    if (this.timerPending()) bits |= 1 << isa.IRQ.TIMER;
    return bits & Number((this.status >> 8n) & 0xffn);
  };

  // ---- バス ----

  CPU.prototype.region = function (a, size) {
    if (a >= MAP.ROM_BASE && a + size <= MAP.ROM_BASE + MAP.ROM_SIZE) return { mem: this.rom, off: a - MAP.ROM_BASE, ro: true };
    if (a >= MAP.IO_BASE && a + size <= MAP.IO_BASE + MAP.IO_SIZE) return { io: true, off: a - MAP.IO_BASE };
    if (a >= MAP.VRAM_BASE && a + size <= MAP.VRAM_BASE + MAP.VRAM_SIZE) return { mem: this.vram, off: a - MAP.VRAM_BASE, vram: true };
    if (a >= MAP.RAM_BASE && a + size <= MAP.RAM_BASE + MAP.RAM_SIZE) return { mem: this.ram, off: a - MAP.RAM_BASE };
    if (a >= MAP.SDRAM_BASE && a + size <= MAP.SDRAM_BASE + MAP.SDRAM_SIZE) {
      if (!this.sdram) this.sdram = new Uint8Array(MAP.SDRAM_SIZE);
      return { mem: this.sdram, off: a - MAP.SDRAM_BASE };
    }
    return null;
  };

  function hex(v) { return '0x' + BigInt.asUintN(64, BigInt(v)).toString(16).padStart(8, '0'); }

  // 整列を確かめてから読む（4.3）。addr は BigInt
  CPU.prototype.read = function (addr, size) {
    if (addr % BigInt(size)) throw new Trap(CAUSE.ALIGN);
    if (addr > M32) throw new Halt('fault', hex(addr) + ' はつながっていない');
    var a = Number(addr), r = this.region(a, size);
    if (!r) throw new Halt('fault', hex(addr) + ' はつながっていない');
    if (r.io) {
      // 入出力は 32bit レジスタ。小さいアクセスはそのバイト位置だけを読む
      var word = BigInt(this.ioRead(r.off & ~3) >>> 0);
      return BigInt.asUintN(size * 8, word >> BigInt((r.off & 3) * 8));
    }
    var m = r.mem, o = r.off, v = 0n;
    if (size === 4) return BigInt((m[o] | (m[o + 1] << 8) | (m[o + 2] << 16) | (m[o + 3] << 24)) >>> 0);
    for (var i = size - 1; i >= 0; i--) v = (v << 8n) | BigInt(m[o + i]);
    return v;
  };

  CPU.prototype.write = function (addr, size, value) {
    if (addr % BigInt(size)) throw new Trap(CAUSE.ALIGN);
    if (addr > M32) throw new Halt('fault', hex(addr) + ' はつながっていない');
    var a = Number(addr), r = this.region(a, size);
    if (!r) throw new Halt('fault', hex(addr) + ' はつながっていない');
    if (r.ro) throw new Halt('fault', hex(addr) + ' は ROM なので書けない');
    if (r.io) {
      // 書き込みはレジスタの先頭バイトを含むときだけ効く（足りない上位は 0）
      if ((r.off & 3) === 0) this.ioWrite(r.off, Number(value & M32));
      return;
    }
    var m = r.mem, o = r.off, v = value;
    for (var i = 0; i < size; i++) { m[o + i] = Number(v & 0xffn); v >>= 8n; }
    if (r.vram) {
      for (var j = o >> 1; j <= (o + size - 1) >> 1; j++) if (j < this.vramDirty.length) this.vramDirty[j] = 1;
      this.vramChanged = true;
    }
  };

  // 入出力レジスタ（仮決め。README 参照）。すべて 32bit、決まった番地以外は 0 を読み、書き込みは無視
  CPU.prototype.ioRead = function (off) {
    switch (off) {
      case IO.UART_STATUS: return 1 | (this.rx.length ? 2 : 0);
      case IO.UART_RX: return this.rx.length ? this.rx.shift() : 0;
      case IO.TIMER_COUNT: return this.timerCount();
      case IO.TIMER_CMP: return this.timerCmp;
      case IO.TIMER_CTRL: return (this.timerEn ? 1 : 0) | (this.timerPending() ? 2 : 0);
      case IO.LED: return this.led;
      default: return 0;
    }
  };
  CPU.prototype.ioWrite = function (off, v) {
    switch (off) {
      case IO.UART_TX: this.onTx(v & 0xff); break;
      case IO.TIMER_COUNT: this.timerBase = (this.now() - v) >>> 0; break;
      case IO.TIMER_CMP: this.timerCmp = v >>> 0; break;
      case IO.TIMER_CTRL: this.timerEn = !!(v & 1); break;
      case IO.LED: this.led = v & 0x3f; this.onLed(this.led); break;
    }
  };

  // ---- レジスタ ----

  // アドレス計算などに使う「レジスタの値そのもの」
  CPU.prototype.raw = function (n) {
    if (n === 0) return 0n;
    if (n < 8) return this.p[n] ? 1n : 0n;
    if (n >= 16 && n < 32) return this.r32[n - 16];
    if (n >= 32 && n < 48) return this.r64[n - 32];
    switch (n) {
      case 48: return this.curPc;
      case 49: return this.sp;
      case 50: return this.lr;
      case 51: return this.epc;
      case 52: return this.cause;
      case 53: return this.evec;
      case 54: return this.status;
    }
    throw new Halt('illegal', 'r' + n + ' は予備レジスタ');
  };
  // 幅 w の命令から読む（特殊レジスタは下位だけ。3.3）
  CPU.prototype.get = function (n, w) { return this.raw(n) & mask(w); };

  // 幅 w の命令から書く（特殊レジスタは上位をゼロ拡張。3.3）
  CPU.prototype.set = function (n, w, v) {
    v &= mask(w);
    if (n === 0) return;
    if (n < 8) { this.p[n] = v !== 0n; return; }
    if (n >= 16 && n < 32) { this.r32[n - 16] = v & M32; return; }
    if (n >= 32 && n < 48) { this.r64[n - 32] = v; return; }
    v &= this.XM;
    switch (n) {
      case 49: this.sp = v; return;
      case 50: this.lr = v; return;
      case 51: this.epc = v; return;
      case 52: this.cause = v; return;
      case 53: this.evec = v; return;
      case 54: this.status = v & STATUS_BITS; return;
    }
    throw new Halt('illegal', 'r' + n + ' には書けない');
  };

  CPU.prototype.user = function () { return (this.status & 1n) === 1n; };

  // ---- 例外・割り込み（6.1） ----

  CPU.prototype.enter = function (cause, epc) {
    var st = this.status;
    this.epc = epc & this.XM;
    this.cause = cause & this.XM;
    // bit2 ← 特権、bit3 ← 割り込み許可、そしてカーネル・割り込み禁止へ
    this.status = (st & ~0xfn) | ((st & 3n) << 2n);
    this.pc = this.evec;
  };

  // ---- デコード（ヘッダ 32bit ごとに結果を覚えておく） ----

  CPU.prototype.decode = function (h) {
    var d = this.decodeCache.get(h);
    if (d) return d;
    var f = isa.decodeHeader(h), row = isa.byOpcode.get(f.opcode);
    d = { row: row, f: f, err: null };
    if (f.width === 3) d.err = 'width 11 は予備';
    else if (f.width === 2 && this.xlen === 32) d.err = '32bit CPU では 64bit 命令は使えない';
    else if (!row) d.err = 'オペコード 0x' + f.opcode.toString(16) + ' はない';
    else {
      d.len = row.length;
      d.w = row.wbits;
      d.kind = row.op & 3;
      d.num = row.op >> 2;
      // 使うレジスタ欄の幅を確かめる（3.3）。SEL の p は即値欄なので実行時に確かめる
      for (var i = 0; i < row.spec.length && !d.err; i++) {
        var s = row.spec[i];
        if (s.cls === 'imm' || s.field === 'imm') continue;
        var e = isa.checkReg(s.cls, f[s.field], row.wbits || this.xlen, s.field === 'rd');
        if (!e && this.xlen === 32 && isa.regKind(f[s.field]) === 'r64') e = '32bit CPU には ' + isa.regName(f[s.field]) + ' がない';
        if (e) d.err = row.mnemonic + ': ' + e;
        else if (s.field === 'rd' && f.rd >= 51 && f.rd <= 54) d.privDest = true;
      }
    }
    this.decodeCache.set(h, d);
    return d;
  };

  // ---- 1 命令 ----

  CPU.prototype.step = function () {
    if (this.halted) return;
    this.ticks++;
    if (this.wfi) {
      if (!this.irqPending()) return;
      this.wfi = false;
    }
    if ((this.status & 2n) && this.irqPending()) {
      var bits = this.irqPending(), n = 0;
      while (!(bits & (1 << n))) n++;
      this.enter(0x80000000n | BigInt(n), this.pc); // 割り込みの印は bit 数によらず bit31（6.3）
    }
    var pc = this.pc;
    this.curPc = pc;
    try {
      this.exec(pc);
      this.steps++;
    } catch (e) {
      if (e instanceof Trap) this.enter(BigInt(e.code), pc);
      else if (e instanceof Halt) {
        this.pc = pc;
        this.halted = { kind: e.kind, message: e.message + '（PC=' + hex(pc) + '）' };
      } else throw e;
    }
  };

  CPU.prototype.run = function (n) {
    for (var i = 0; i < n && !this.halted; i++) this.step();
    return i;
  };

  CPU.prototype.exec = function (pc) {
    var h = Number(this.read(pc, 4));
    var d = this.decode(h);
    if (d.err) throw new Halt('illegal', d.err);
    var row = d.row, f = d.f, w = d.w, len = d.len;
    var imm = 0n;
    if (w === 32) imm = this.read(pc + 4n, 4);
    else if (w === 64) imm = this.read(pc + 4n, 4) | (this.read(pc + 8n, 4) << 32n);
    if (this.trace) this.trace(pc, isa.disasm(row, f, imm));
    if (d.privDest && this.user()) throw new Trap(CAUSE.PRIV);
    var next = (pc + BigInt(len)) & this.XM;
    this.pc = next;
    var M = mask(w || 32);

    switch (row.group) {
      case 0: return this.execSystem(row, pc);
      case 1:
      case 2:
      case 3: {
        if (row.form === 'SEL') {
          var pn = Number(imm & 63n);
          var e = isa.checkReg('p', pn, w, false);
          if (e) throw new Halt('illegal', 'SEL: ' + e);
          this.set(f.rd, w, this.raw(pn) ? this.get(f.rs1, w) : this.get(f.rs2, w));
          return;
        }
        var a = this.get(f.rs1, w), b;
        if (row.form === 'U') b = 0n;
        else if (d.kind === 0) b = this.get(f.rs2, w);
        else if (d.kind === 1) b = imm & M;
        else b = this.read((this.raw(f.rs2) + imm) & M, w / 8);
        var r = row.group === 1 ? arith(d.num, a, b, w) : row.group === 2 ? logic(d.num, a, b, w) : compare(d.num, a, b, w);
        this.set(f.rd, w, r);
        return;
      }
      case 4: {
        var addr = (this.raw(f.rs1) + imm) & M;
        if (row.op < 0x10) {
          var size = LOAD_SIZE[row.op], v = this.read(addr, size);
          if (row.op & 1) v = BigInt.asUintN(w, BigInt.asIntN(size * 8, v));
          this.set(f.rd, w, v);
        } else if (row.op < 0x20) {
          var ss = STORE_SIZE[row.op - 0x10];
          this.write(addr, ss, this.get(f.rs2, w) & mask8(ss));
        } else {
          // SWAP：書く値を先に読んでおく（rd と rs2 が同じでもよいように）
          var nv = this.get(f.rs2, w), old = this.read(addr, w / 8);
          this.write(addr, w / 8, nv);
          this.set(f.rd, w, old);
        }
        return;
      }
      case 5: {
        switch (row.op) {
          case 0: this.pc = imm & M; return;
          case 1: if (this.p[f.rs1]) this.pc = imm & M; return;
          case 2: this.lr = next; this.pc = imm & M; return;
          case 3: this.pc = this.lr & M; return;
          case 4: this.pc = this.raw(f.rs1) & M; return;
          case 5: { var t = this.raw(f.rs1) & M; this.lr = next; this.pc = t; return; }
        }
        break;
      }
      case 6: {
        var src = this.raw(f.rs1);
        switch (row.op) {
          case 0: this.set(f.rd, 64, src & M32); return;
          case 1: this.set(f.rd, 64, BigInt.asUintN(64, BigInt.asIntN(32, src & M32))); return;
          case 2: this.set(f.rd, 32, src & M32); return;
          case 3: this.set(f.rd, w, src ? 1n : 0n); return;
        }
        break;
      }
    }
    throw new Halt('illegal', row.mnemonic + ' は未実装');
  };

  function mask8(bytes) { return bytes === 8 ? M64 : (1n << BigInt(bytes * 8)) - 1n; }

  CPU.prototype.execSystem = function (row, pc) {
    var op = row.op;
    // ユーザーモードで使えるのは NOP と SYSCALL だけ（6.4）
    if (this.user() && op !== 1 && op !== 3) throw new Trap(CAUSE.PRIV);
    switch (op) {
      case 0: this.pc = pc; throw new Halt('hlt', 'HLT');
      case 1: return;
      case 2: {
        var st = this.status;
        this.status = (st & ~3n) | ((st >> 2n) & 3n);
        this.pc = this.epc;
        return;
      }
      case 3: throw new Trap(CAUSE.SYSCALL);
      case 4: this.wfi = true; return;
    }
  };

  function arith(num, a, b, w) {
    var M = mask(w), sa, sb;
    switch (num) {
      case 0: return (a + b) & M;
      case 1: return (a - b) & M;
      case 2: return (a * b) & M;
      case 3: return ((BigInt.asIntN(w, a) * BigInt.asIntN(w, b)) >> BigInt(w)) & M;
      case 4: return ((a * b) >> BigInt(w)) & M;
    }
    if (b === 0n) throw new Trap(CAUSE.DIVZERO);
    sa = BigInt.asIntN(w, a); sb = BigInt.asIntN(w, b);
    switch (num) {
      case 5: return (sa / sb) & M; // 最小値 ÷ −1 は 2^(w-1) になり、マスクで最小値に戻る（5.3）
      case 6: return a / b;
      case 7: return (sa % sb) & M;
      case 8: return a % b;
    }
    throw new Halt('illegal', '算術 ' + num + ' はない');
  }

  function logic(num, a, b, w) {
    var M = mask(w), sh = b & BigInt(w - 1); // シフト量は幅−1 でマスク（5.4）
    switch (num) {
      case 0: return a & b;
      case 1: return a | b;
      case 2: return a ^ b;
      case 3: return (a << sh) & M;
      case 4: return a >> sh;
      case 5: return (BigInt.asIntN(w, a) >> sh) & M;
      case 6: { var n = 0; for (var i = w - 1; i >= 0 && !((a >> BigInt(i)) & 1n); i--) n++; return BigInt(n); }
      case 7: { var c = 0; for (var x = a; x; x >>= 1n) c += Number(x & 1n); return BigInt(c); }
    }
    throw new Halt('illegal', '論理 ' + num + ' はない');
  }

  function compare(num, a, b, w) {
    var sa = BigInt.asIntN(w, a), sb = BigInt.asIntN(w, b), r;
    switch (num) {
      case 0: r = a === b; break;
      case 1: r = a !== b; break;
      case 2: r = sa < sb; break;
      case 3: r = a < b; break;
      case 4: r = sa >= sb; break;
      case 5: r = a >= b; break;
      default: throw new Halt('illegal', '比較 ' + num + ' はない');
    }
    return r ? 1n : 0n;
  }

  // レジスタ一覧（Verilog のテストベンチと同じ書式。比べるため）
  CPU.prototype.dumpRegs = function () {
    var self = this, xd = this.xlen / 4;
    function h(v, d) { return BigInt.asUintN(d * 4, v).toString(16).padStart(d, '0'); }
    var lines = [];
    lines.push('pc=' + h(this.pc, xd) + ' sp=' + h(this.sp, xd) + ' lr=' + h(this.lr, xd));
    lines.push('epc=' + h(this.epc, xd) + ' cause=' + h(this.cause, xd) + ' evec=' + h(this.evec, xd) + ' status=' + h(this.status, xd));
    lines.push('p1-p7=' + this.p.slice(1).map(function (b) { return b ? '1' : '0'; }).join(''));
    for (var i = 0; i < 16; i += 4) {
      lines.push([0, 1, 2, 3].map(function (k) { return ('r' + (16 + i + k)).padStart(3) + '=' + h(self.r32[i + k], 8); }).join(' '));
    }
    if (this.xlen === 64) {
      for (var j = 0; j < 16; j += 2) {
        lines.push([0, 1].map(function (k) { return 'r' + (32 + j + k) + '=' + h(self.r64[j + k], 16); }).join(' '));
      }
    }
    return lines.join('\n') + '\n';
  };

  CPU.Trap = Trap;
  CPU.Halt = Halt;
  return CPU;
});
