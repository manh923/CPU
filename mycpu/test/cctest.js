#!/usr/bin/env node
// C コンパイラ（cc/）のテスト：chibicc のテスト（cc/test/*.c）を、この CPU 向けにコンパイルしてシミュレータで動かす
//   node test/cctest.js [テスト名 ...]     … 名前を省くと全部。結果を 1 行ずつ出す
// MyDOS は使わない。ROM に小さなカーネル（SYSCALL 0 = 終了、1 = 1 文字、2 = 文字列）を置き、プログラムを直接呼ぶ。
// テストは最後に "OK" を出して main から 0 を返せば成功。
// test/run.js からは run(names) を呼ぶ。
'use strict';
const fs = require('fs');
const path = require('path');
const { buildAsm, CcError } = require('../tools/cc.js');
const { assemble, AsmError } = require('../lib/assembler.js');
const CPU = require('../lib/cpu.js');

const DIR = path.join(__dirname, '..', 'cc', 'test');

const KERNEL = `
        .org 0
        ADDI32 sp, r0, 0x01800000
        ADDI32 evec, r0, trap
        ADDI32 r16, r0, 0
        JMP32 start
; SYSCALL だけを受け持つ（ほかの例外は r16 = 0xBAD0 + 理由 で止まる）
trap:   CMPNEI32 p1, cause, 3
        BR32 p1, .bad
        CMPEQI32 p1, r23, 0
        BR32 p1, .exit
        CMPEQI32 p1, r23, 1
        BR32 p1, .putc
        CMPEQI32 p1, r23, 2
        BR32 p1, .puts
        ADDI32 r16, r0, -1
.ret:   ADDI32 epc, epc, 4
        ERET
.putc:  STORE32_32 r16, r0, 0x00010000
        JMP32 .ret
.puts:  LOAD8U_32 r17, r16, 0
        CMPEQI32 p1, r17, 0
        BR32 p1, .ret
        STORE32_32 r17, r0, 0x00010000
        ADDI32 r16, r16, 1
        JMP32 .puts
.exit:  HLT
.bad:   ADDI32 r16, cause, 0xBAD0
        HLT
`;

// 1 つのテストを動かす → { ok, out, why }
function runOne(name, max = 50_000_000) {
  let asm;
  try {
    asm = KERNEL + buildAsm([path.join(DIR, name + '.c'), path.join(DIR, 'common.c')], { includes: [DIR, path.join(DIR, '..')] });
  } catch (e) {
    if (!(e instanceof CcError)) throw e;
    return { ok: false, out: '', why: 'コンパイルできない：' + e.message.split('\n').slice(0, 3).join(' / ') };
  }
  let image;
  try {
    image = assemble(asm).image;
  } catch (e) {
    if (!(e instanceof AsmError)) throw e;
    return { ok: false, out: '', why: 'アセンブルできない：' + e.errors.slice(0, 3).map((x) => `${x.line}: ${x.message}`).join(' / ') };
  }
  let out = '';
  const cpu = new CPU({ xlen: 32, onTx: (b) => { out += String.fromCharCode(b); } });
  cpu.load(image);
  cpu.run(max);
  const code = Number(cpu.get(16, 32));
  if (!cpu.halted) return { ok: false, out, why: `${max} 命令で終わらない` };
  if (cpu.halted.kind !== 'hlt') return { ok: false, out, why: cpu.halted.message };
  if ((code & 0xFFF0) === 0xBAD0) return { ok: false, out, why: `例外（理由 ${code & 15}）PC=${Number(cpu.epc).toString(16)}` };
  if (code !== 0) return { ok: false, out, why: `終了コード ${code}：` + out.trim().split('\n').slice(-1)[0] };
  if (!/OK\s*$/.test(out)) return { ok: false, out, why: 'OK が出ない' };
  return { ok: true, out, why: '' };
}

function allTests() {
  return fs.readdirSync(DIR).filter((f) => f.endsWith('.c') && f !== 'common.c').map((f) => f.slice(0, -2)).sort();
}

function run(names) {
  return (names && names.length ? names : allTests()).map((n) => ({ name: n, ...runOne(n) }));
}

if (require.main === module) {
  const results = run(process.argv.slice(2));
  for (const r of results) console.log(`${r.ok ? 'ok' : 'NG'}  ${r.name.padEnd(14)} ${r.why}`);
  const ng = results.filter((r) => !r.ok).length;
  console.log(`${results.length - ng} / ${results.length} ok`);
}

module.exports = { run, runOne, allTests };
