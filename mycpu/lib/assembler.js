// アセンブラ本体。opcodes.csv（lib/opcodes.js）の表だけを見て命令を組み立てる。
//
// 書き方:
//   label:  ADDI32 r16, r0, 'A'     ; コメント
//   .loop:                          ; '.' で始まるラベルは直前のラベルの中だけで有効
//   NAME = 0x10000                  ; 定数（.equ NAME, 0x10000 も可）
// 疑似命令: .org .align .space .byte .half .word .dword .ascii .asciz .equ
// 命令は自動で 4 バイト境界にそろえる。
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./isa.js'));
  else root.MyCPU.Assembler = factory(root.MyCPU.isa);
})(typeof self !== 'undefined' ? self : this, function (isa) {
  'use strict';

  function AsmError(errors) {
    this.name = 'AsmError';
    this.errors = errors;
    this.message = errors.map(function (e) { return e.line + ': ' + e.message; }).join('\n');
  }
  AsmError.prototype = Object.create(Error.prototype);

  // ---- 字句 ----

  function stripComment(line) {
    var q = null;
    for (var i = 0; i < line.length; i++) {
      var c = line[i];
      if (q) {
        if (c === '\\') i++;
        else if (c === q) q = null;
      } else if (c === '"' || c === "'") q = c;
      else if (c === ';') return line.slice(0, i);
    }
    return line;
  }

  function splitOperands(s) {
    var out = [], cur = '', q = null, depth = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s[i];
      if (q) {
        cur += c;
        if (c === '\\') cur += s[++i] || '';
        else if (c === q) q = null;
      } else if (c === '"' || c === "'") { q = c; cur += c; }
      else if (c === '(') { depth++; cur += c; }
      else if (c === ')') { depth--; cur += c; }
      else if (c === ',' && depth === 0) { out.push(cur.trim()); cur = ''; }
      else cur += c;
    }
    if (cur.trim() !== '' || out.length) out.push(cur.trim());
    return out;
  }

  var ESC = { n: 10, r: 13, t: 9, '0': 0, '\\': 92, '"': 34, "'": 39, a: 7, b: 8, e: 27 };
  function parseString(tok) {
    if (!/^".*"$/.test(tok)) throw new Error('文字列は "..." で書く: ' + tok);
    var s = tok.slice(1, -1), out = [];
    for (var i = 0; i < s.length; i++) {
      if (s[i] !== '\\') {
        var code = s.charCodeAt(i);
        if (code > 255) throw new Error('1 バイトに入らない文字: ' + s[i]);
        out.push(code);
        continue;
      }
      var e = s[++i];
      if (e === 'x') { out.push(parseInt(s.substr(i + 1, 2), 16)); i += 2; }
      else if (Object.prototype.hasOwnProperty.call(ESC, e)) out.push(ESC[e]);
      else throw new Error('不明なエスケープ: \\' + e);
    }
    return out;
  }

  // ---- 式（BigInt） ----

  function tokenizeExpr(s) {
    var toks = [], i = 0, m;
    var re = /\s*(?:(0x[0-9a-f_]+|0b[01_]+|\d[\d_]*)|('(?:\\x[0-9a-f]{2}|\\.|[^\\'])')|([A-Za-z_.][\w.]*)|(<<|>>|[-+*/%&|^~()]))/iy;
    while (i < s.length) {
      re.lastIndex = i;
      if (!(m = re.exec(s))) {
        if (/^\s*$/.test(s.slice(i))) break;
        throw new Error('式を読めない: ' + s.slice(i));
      }
      i = re.lastIndex;
      if (m[1]) toks.push({ t: 'num', v: BigInt(m[1].replace(/_/g, '')) });
      else if (m[2]) toks.push({ t: 'num', v: BigInt(parseString('"' + m[2].slice(1, -1) + '"')[0]) });
      else if (m[3]) toks.push({ t: 'id', v: m[3] });
      else toks.push({ t: 'op', v: m[4] });
    }
    return toks;
  }

  var BINARY = { '|': 1, '^': 2, '&': 3, '<<': 4, '>>': 4, '+': 5, '-': 5, '*': 6, '/': 6, '%': 6 };

  // lookup(name) は値（BigInt）か undefined を返す。未定義があれば null を返す。
  function evalExpr(s, lookup) {
    var toks = tokenizeExpr(s), pos = 0, unknown = false;
    if (!toks.length) throw new Error('式が空');
    function unary() {
      var t = toks[pos++];
      if (!t) throw new Error('式が途中で終わっている: ' + s);
      if (t.t === 'num') return t.v;
      if (t.t === 'id') {
        var v = lookup(t.v);
        if (v === undefined) { unknown = true; return 0n; }
        return v;
      }
      if (t.v === '-') return -unary();
      if (t.v === '+') return unary();
      if (t.v === '~') return ~unary();
      if (t.v === '(') {
        var v2 = binary(0);
        if (!toks[pos] || toks[pos].v !== ')') throw new Error(') がない: ' + s);
        pos++;
        return v2;
      }
      throw new Error('式を読めない: ' + s);
    }
    function binary(minPrec) {
      var lhs = unary();
      for (;;) {
        var t = toks[pos];
        if (!t || t.t !== 'op' || !BINARY[t.v] || BINARY[t.v] <= minPrec) return lhs;
        pos++;
        var rhs = binary(BINARY[t.v]);
        switch (t.v) {
          case '+': lhs += rhs; break;
          case '-': lhs -= rhs; break;
          case '*': lhs *= rhs; break;
          case '/': if (!rhs) { if (unknown) break; throw new Error('0 で割っている'); } lhs /= rhs; break;
          case '%': if (!rhs) { if (unknown) break; throw new Error('0 で割っている'); } lhs %= rhs; break;
          case '<<': lhs <<= rhs; break;
          case '>>': lhs >>= rhs; break;
          case '&': lhs &= rhs; break;
          case '|': lhs |= rhs; break;
          case '^': lhs ^= rhs; break;
        }
      }
    }
    var v = binary(0);
    if (pos !== toks.length) throw new Error('式の後ろに余計なものがある: ' + s);
    return unknown ? null : v;
  }

  // ---- 本体 ----

  var DATA_SIZE = { '.byte': 1, '.half': 2, '.word': 4, '.dword': 8 };

  function parseLines(source) {
    var stmts = [], errors = [];
    source.split(/\r?\n/).forEach(function (raw, idx) {
      var line = idx + 1, s = stripComment(raw), m;
      try {
        while ((m = /^\s*([A-Za-z_.][\w.]*)\s*:(?!:)/.exec(s))) {
          stmts.push({ line: line, kind: 'label', name: m[1], text: raw });
          s = s.slice(m[0].length);
        }
        if ((m = /^\s*([A-Za-z_][\w.]*)\s*=\s*(.+)$/.exec(s))) {
          stmts.push({ line: line, kind: 'equ', name: m[1], expr: m[2].trim(), text: raw });
          return;
        }
        if ((m = /^\s*(\.?[A-Za-z_][\w.]*)\s*(.*)$/.exec(s))) {
          var name = m[1], ops = splitOperands(m[2]);
          if (name[0] === '.') {
            var dir = name.toLowerCase();
            if (dir === '.equ' || dir === '.set') {
              if (ops.length !== 2) throw new Error(dir + ' NAME, 値');
              stmts.push({ line: line, kind: 'equ', name: ops[0], expr: ops[1], text: raw });
            } else stmts.push({ line: line, kind: 'dir', dir: dir, ops: ops, text: raw });
          } else {
            stmts.push({ line: line, kind: 'insn', mnemonic: name.toUpperCase(), ops: ops, text: raw });
          }
        } else if (s.trim() !== '') throw new Error('読めない行: ' + s.trim());
      } catch (e) {
        errors.push({ line: line, message: e.message });
      }
    });
    return { stmts: stmts, errors: errors };
  }

  function assemble(source) {
    var parsed = parseLines(source);
    var errors = parsed.errors;
    var stmts = parsed.stmts;
    var symbols = new Map();
    var scope = '';

    function qualify(name) { return name[0] === '.' ? scope + name : name; }
    function lookup(name) { return symbols.get(qualify(name)); }
    function evalNow(expr) {
      var v = evalExpr(expr, lookup);
      if (v === null) throw new Error('ここでは前で決まった値しか使えない: ' + expr);
      return v;
    }
    function define(name, value) {
      var q = qualify(name);
      if (symbols.has(q)) throw new Error('二重定義: ' + q);
      symbols.set(q, value);
    }

    // 1 パス目：番地を決める
    var pc = 0n;
    stmts.forEach(function (st, idx) {
      try {
        if (st.kind === 'label') {
          if (st.name[0] !== '.') scope = st.name;
          // 直後が命令なら、命令と同じく 4 バイト境界にそろえた番地をラベルにする
          var j = idx + 1;
          while (stmts[j] && (stmts[j].kind === 'label' || stmts[j].kind === 'equ')) j++;
          if (stmts[j] && stmts[j].kind === 'insn') pc = (pc + 3n) & ~3n;
          define(st.name, pc);
        } else if (st.kind === 'equ') {
          define(st.name, evalNow(st.expr));
        } else if (st.kind === 'insn') {
          var row = isa.byMnemonic.get(st.mnemonic);
          if (!row) throw new Error('知らない命令: ' + st.mnemonic);
          pc = (pc + 3n) & ~3n;
          st.row = row;
          st.addr = pc;
          pc += BigInt(row.length);
        } else {
          st.addr = pc;
          pc = layoutDirective(st, pc, evalNow);
        }
      } catch (e) {
        errors.push({ line: st.line, message: e.message });
      }
      st.scope = scope;
    });
    if (errors.length) throw new AsmError(errors);

    // 2 パス目：バイト列を作る
    var chunks = [];
    stmts.forEach(function (st) {
      scope = st.scope;
      try {
        if (st.kind === 'insn') {
          chunks.push({ addr: st.addr, bytes: encodeInsn(st, lookupFinal), st: st });
        } else if (st.kind === 'dir' && st.bytes) {
          chunks.push({ addr: st.addr, bytes: st.bytes(lookupFinal), st: st });
        }
      } catch (e) {
        errors.push({ line: st.line, message: e.message });
      }
    });
    function lookupFinal(name) { return symbols.get(qualify(name)); }
    if (errors.length) throw new AsmError(errors);

    return buildResult(chunks, symbols, errors);
  }

  function layoutDirective(st, pc, evalNow) {
    var ops = st.ops;
    switch (st.dir) {
      case '.org': {
        if (ops.length !== 1) throw new Error('.org 番地');
        var a = evalNow(ops[0]);
        if (a < pc) throw new Error('.org で前に戻ることはできない');
        st.addr = a;
        return a;
      }
      case '.align': {
        if (ops.length !== 1) throw new Error('.align バイト数');
        var n = evalNow(ops[0]);
        if (n <= 0n) throw new Error('.align は 1 以上');
        var to = ((pc + n - 1n) / n) * n;
        var len = Number(to - pc);
        st.bytes = function () { return new Array(len).fill(0); };
        return to;
      }
      case '.space': {
        if (ops.length < 1 || ops.length > 2) throw new Error('.space バイト数[, 埋める値]');
        var size = Number(evalNow(ops[0]));
        var fill = ops[1] ? Number(BigInt.asUintN(8, evalNow(ops[1]))) : 0;
        st.bytes = function () { return new Array(size).fill(fill); };
        return pc + BigInt(size);
      }
      case '.ascii':
      case '.asciz': {
        var bytes = [];
        ops.forEach(function (o) { bytes = bytes.concat(parseString(o)); });
        if (st.dir === '.asciz') bytes.push(0);
        st.bytes = function () { return bytes; };
        return pc + BigInt(bytes.length);
      }
      default: {
        var w = DATA_SIZE[st.dir];
        if (!w) throw new Error('知らない疑似命令: ' + st.dir);
        if (!ops.length) throw new Error(st.dir + ' に値がない');
        var count = 0;
        ops.forEach(function (o) {
          if (o[0] === '"') {
            if (w !== 1) throw new Error('文字列は .byte か .ascii で');
            count += parseString(o).length;
          } else count += w;
        });
        st.bytes = function (lookup) {
          var out = [];
          ops.forEach(function (o) {
            if (o[0] === '"') { out = out.concat(parseString(o)); return; }
            var v = evalExpr(o, lookup);
            if (v === null) throw new Error('未定義の名前: ' + o);
            checkRange(v, w * 8, o);
            pushLE(out, v, w);
          });
          return out;
        };
        return pc + BigInt(count);
      }
    }
  }

  function checkRange(v, bits, text) {
    var lo = -(1n << BigInt(bits - 1)), hi = (1n << BigInt(bits)) - 1n;
    if (v < lo || v > hi) throw new Error(text + ' は ' + bits + 'bit に入らない');
  }

  function pushLE(out, v, n) {
    var u = BigInt.asUintN(n * 8, v);
    for (var i = 0; i < n; i++) { out.push(Number(u & 0xffn)); u >>= 8n; }
  }

  function encodeInsn(st, lookup) {
    var row = st.row;
    if (st.ops.length !== row.spec.length) {
      throw new Error(row.mnemonic + ' のオペランドは ' + (row.operands.join(', ') || 'なし'));
    }
    var f = { rd: 0, rs1: 0, rs2: 0 }, imm = 0n;
    row.spec.forEach(function (s, i) {
      var tok = st.ops[i];
      if (s.cls === 'imm') {
        var v = evalExpr(tok, lookup);
        if (v === null) throw new Error('未定義の名前: ' + tok);
        checkRange(v, row.wbits, tok);
        imm = v;
        return;
      }
      var n = isa.parseReg(tok);
      if (n === null) throw new Error('レジスタではない: ' + tok);
      var err = isa.checkReg(s.cls, n, row.wbits, s.field === 'rd');
      if (err) throw new Error(row.mnemonic + ': ' + err);
      if (s.field === 'imm') imm = BigInt(n);
      else f[s.field] = n;
    });
    var bytes = [];
    pushLE(bytes, BigInt(isa.encodeHeader(row.opcode, f.rd, f.rs1, f.rs2)), 4);
    if (row.wbits) pushLE(bytes, imm, row.wbits / 8);
    return bytes;
  }

  function hex(v, n) { return v.toString(16).toUpperCase().padStart(n, '0'); }

  function buildResult(chunks, symbols) {
    // 重なりを確認し、番地順に並べる
    chunks.sort(function (a, b) { return a.addr < b.addr ? -1 : a.addr > b.addr ? 1 : 0; });
    var end = 0n;
    chunks.forEach(function (c) {
      if (c.addr < end && c.bytes.length) {
        throw new AsmError([{ line: c.st.line, message: '番地 0x' + hex(c.addr, 8) + ' が前の内容と重なる' }]);
      }
      end = c.addr + BigInt(c.bytes.length);
    });
    if (end > 0x02000000n) throw new AsmError([{ line: 0, message: 'プログラムが 32MB を超える' }]);
    var image = new Uint8Array(Number(end));
    chunks.forEach(function (c) { image.set(c.bytes, Number(c.addr)); });

    var listing = [];
    chunks.forEach(function (c) {
      var b = c.bytes, code;
      if (c.st.kind === 'insn') {
        var words = [];
        for (var i = 0; i < b.length; i += 4) {
          words.push(hex((b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0, 8));
        }
        code = words.join(' ');
      } else {
        code = b.slice(0, 8).map(function (x) { return hex(x, 2); }).join(' ') + (b.length > 8 ? ' …' : '');
      }
      listing.push(hex(c.addr, 8) + '  ' + code.padEnd(28) + '  ' + c.st.line.toString().padStart(4) + '  ' + c.st.text.trim());
    });
    listing.push('', '; シンボル');
    Array.from(symbols.keys()).sort().forEach(function (k) {
      listing.push('; ' + k.padEnd(24) + ' 0x' + hex(BigInt.asUintN(64, symbols.get(k)), 8));
    });

    return { image: image, end: end, symbols: symbols, listing: listing.join('\n') + '\n' };
  }

  // $readmemh 用：32bit ワードを 1 行ずつ（ROM の大きさまで）
  function toReadmemh(image, words) {
    var out = [];
    for (var i = 0; i < words; i++) {
      var a = i * 4;
      var w = (image[a] | 0) | ((image[a + 1] | 0) << 8) | ((image[a + 2] | 0) << 16) | ((image[a + 3] | 0) << 24);
      out.push(hex(w >>> 0, 8));
    }
    return out.join('\n') + '\n';
  }

  return { assemble: assemble, toReadmemh: toReadmemh, evalExpr: evalExpr, AsmError: AsmError };
});
