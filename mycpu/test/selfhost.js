#!/usr/bin/env node
// セルフホストの実験：MyDOS（JS のシミュレータ）の上で CC.EXE（chibicc をこの CPU 向けにコンパイルしたもの）を動かす
//   node test/selfhost.js "build hello;hello" hello.c ...
//     コマンドは ; で区切る。後ろに並べたファイルもカードに入れる（名前は 8.3 に縮める）
//   PROF=1 node test/selfhost.js "cc hello.c" hello.c   … 最初のコマンドで、997 命令ごとに PC を見て関数ごとに数える
//   （PROF=as なら AS.EXE の関数の名前で）
// カードは disk/ から作るもの（MYDOS.SYS・CC.EXE・AS.EXE・BUILD.BAT、INCLUDE\ のヘッダ、LIB\ の CRT0.S・LIBC.S、SRC\CC\ など。tools/cc.js の diskSources）。
// 終わった後のカード（パーティションの中身）は一時フォルダの selfhost.img（mtools で読める）
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const ROOT = path.join(__dirname, '..');
const CPU = require('../lib/cpu.js');
const SDCard = require('../lib/sdcard.js');
const { assemble } = require('../lib/assembler.js');
const { makeDisk } = require('../lib/disk.js');
const { buildAsm, diskSources, dosName } = require('../tools/cc.js');

const cmds = (process.argv[2] || 'cc hello.c').split(';');
// カードは disk/ と同じもの（C コンパイラ一式も入る）に、後ろに並べたファイルを足す
const srcs = diskSources(path.join(ROOT, 'disk'));
const ccAsm = buildAsm(fs.readdirSync(path.join(ROOT, 'cc')).filter((f) => f.endsWith('.c')).map((f) => path.join(ROOT, 'cc', f)));
for (const f of process.argv.slice(3)) srcs.push({ name: dosName(path.basename(f)), contents: fs.readFileSync(f) });

const disk = makeDisk(srcs, { type: 'fat32' });
let out = '';
const cpu = new CPU({ xlen: 32, onTx: (b) => { out += String.fromCharCode(b); }, sd: new SDCard(disk) });
cpu.load(assemble(fs.readFileSync(path.join(ROOT, 'examples/bios.asm'), 'utf8')).image);
cpu.pushRx(Buffer.from(' ' + cmds.join('\r') + '\r', 'latin1'));

const prompts = () => (out.match(/C:\\[^>\n]*>/g) || []).length;   // C:\> や C:\SUB> の数
const t = Date.now();
const max = Number(process.env.MAX || 5e9);
const log = [];
if (process.env.PROF) {
  // 関数の名前（C の大域の名前・static な関数）を番地の順に
  const profAsm = process.env.PROF === 'as' ? buildAsm([path.join(ROOT, 'disk/as.c')]) : ccAsm;
  const syms = [...assemble(profAsm).symbols].filter(([n]) => /^(_|L[0-9a-f]{8}_)/.test(n))
    .map(([n, v]) => [Number(v), n]).sort((a, b) => a[0] - b[0]);
  while (prompts() < 1) cpu.run(1e5);
  const hist = new Map();
  let total = 0;
  const start = cpu.steps;
  while (prompts() < 2 && cpu.steps - start < max) {
    cpu.run(997);
    const pc = Number(cpu.pc);
    if (pc < 0x1000000) continue;
    let lo = 0, hi = syms.length - 1;
    while (lo < hi) { const m = (lo + hi + 1) >> 1; if (syms[m][0] <= pc) lo = m; else hi = m - 1; }
    hist.set(syms[lo][1], (hist.get(syms[lo][1]) || 0) + 1);
    total++;
  }
  log.push(`${cmds[0]}: ${((cpu.steps - start) / 1e6).toFixed(1)}M 命令`);
  for (const [n, c] of [...hist].sort((a, b) => b[1] - a[1]).slice(0, 40)) log.push(`${(100 * c / total).toFixed(1).padStart(5)}%  ${n}`);
} else {
  let seen = 0, last = 0;
  while (cpu.steps < max && !cpu.halted) {
    cpu.run(2e5);
    for (const n = prompts(); seen < n; seen++) {
      if (seen > 0) log.push(`${cmds[seen - 1]}: ${((cpu.steps - last) / 1e6).toFixed(1)}M 命令`);
      last = cpu.steps;
    }
    if (seen > cmds.length) break;
  }
}
console.log(out.slice(out.indexOf('C:\\>')));
// 最後のプログラムが使ったヒープ（libc/stdlib.c の heap_top − ___heap_start）
{
  const syms = assemble(ccAsm).symbols;
  const top = [...syms].find(([n]) => /^L[0-9a-f]{8}_heap_top$/.test(n));
  if (top) {
    const used = Number(cpu.read(BigInt(top[1]), 4)) - Number(syms.get('___heap_start'));
    log.push(`CC.EXE のヒープ：${(used / 1e6).toFixed(2)}MB（最後に動いたのが CC.EXE なら）`);
  }
}
if (cpu.halted) log.unshift(`CPU が止まった：${cpu.halted.kind} ${cpu.halted.message}`);
console.log(`\n[${(cpu.steps / 1e6).toFixed(0)}M 命令, ${(Date.now() - t) / 1000} 秒]\n` + log.join('\n'));
fs.writeFileSync(path.join(os.tmpdir(), 'selfhost.img'), disk.toBuffer().subarray(disk.info.partStart * 512));
