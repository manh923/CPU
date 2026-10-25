#!/usr/bin/env node
// C で書いたアセンブラ（disk/as.c）のテスト。PC の gcc でビルドして、JS のアセンブラ（lib/assembler.js）と比べる
//   node test/astest.js
//   1. 手元のアセンブリ全部（例題・BIOS・MyDOS・C から作ったもの）が、JS と 1 バイトも違わない
//   2. crt0・ライブラリ・プログラムを別々のファイルのまま渡しても（リンカの代わり）、tools/cc.js の .EXE と同じ
//   3. -lib LIBC（先にアセンブルした C ライブラリ）でつないだ .EXE が動く（MyDOS の BUILD.BAT と同じつなぎ方）
// test/run.js からは run() を呼ぶ（gcc がなければ null）
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const { assemble } = require('../lib/assembler.js');
const { makeFile } = require('../lib/disk.js');
const { buildAsm, buildLib, compileFile } = require('../tools/cc.js');
const CPU = require('../lib/cpu.js');

const ROOT = path.join(__dirname, '..');

function run() {
  if (spawnSync('gcc', ['--version']).error) return null;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mycpu-as-'));
  const as = path.join(tmp, 'as');
  const results = [];
  try {
    execFileSync('gcc', ['-O2', '-o', as, path.join(ROOT, 'disk/as.c')], { stdio: ['ignore', 'ignore', 'pipe'] });

    // 1. JS と同じバイト列
    const list = [];
    for (const d of ['examples', 'examples/uartboot', 'disk', 'test']) {
      for (const f of fs.readdirSync(path.join(ROOT, d))) if (f.endsWith('.asm')) list.push(path.join(ROOT, d, f));
    }
    for (const c of ['disk/primes.c', 'disk/as.c']) {
      const f = path.join(tmp, path.basename(c) + '.asm');
      fs.writeFileSync(f, buildAsm([path.join(ROOT, c)]));
      list.push(f);
    }
    for (const f of list) {
      const want = Buffer.from(assemble(fs.readFileSync(f, 'utf8')).image);
      const out = path.join(tmp, 'out.bin');
      const r = spawnSync(as, ['-bin', out, f], { encoding: 'utf8' });
      if (r.status !== 0) { results.push({ name: path.basename(f), ok: false, why: r.stderr.split('\n')[0] }); continue; }
      const got = fs.readFileSync(out);       // C の出力は、中身のあるいちばん小さい番地から
      const pre = want.subarray(0, want.length - got.length);
      const ok = want.subarray(want.length - got.length).equals(got) && pre.every((b) => b === 0);
      results.push({ name: path.basename(f), ok, why: ok ? '' : `${got.length} / ${want.length} バイト` });
    }

    // 2. 別々のファイルでリンク
    const libc = path.join(ROOT, 'libc');
    const asms = fs.readdirSync(libc).filter((f) => f.endsWith('.s') && f !== 'crt0.s').sort().map((f) => path.join(libc, f));
    const cs = fs.readdirSync(libc).filter((f) => f.endsWith('.c')).sort().map((f) => path.join(libc, f));
    for (const prog of ['disk/primes.c', 'disk/edit.c']) {
      const files = [path.join(libc, 'crt0.s'), ...asms];
      for (const c of [path.join(ROOT, prog), ...cs]) {
        const s = path.join(tmp, path.basename(c) + '.s');
        fs.writeFileSync(s, compileFile(c));
        files.push(s);
      }
      const exe = path.join(tmp, 'X.EXE');
      const r = spawnSync(as, ['-b', '0x1000000', '-o', exe, ...files], { encoding: 'utf8' });
      const want = Buffer.from(makeFile('x.exe.asm', buildAsm([path.join(ROOT, prog)], { gc: false })).data);
      const ok = r.status === 0 && fs.readFileSync(exe).equals(want);
      results.push({ name: 'link ' + prog, ok, why: ok ? '' : (r.stderr || 'バイト列が違う').split('\n')[0] });
    }

    // 3. -lib LIBC：LIBC.BIN・LIBC.SYM を作り、プログラムだけアセンブルしてつなぐ。cctest の小さなカーネルで動かす
    const lib = buildLib();
    fs.writeFileSync(path.join(tmp, 'LIBC.BIN'), lib.bin);
    fs.writeFileSync(path.join(tmp, 'LIBC.SYM'), lib.sym);
    fs.copyFileSync(path.join(libc, 'crt0.s'), path.join(tmp, 'CRT0.S'));
    fs.writeFileSync(path.join(tmp, 'PRIMES.S'), compileFile(path.join(ROOT, 'disk/primes.c')));
    const r3 = spawnSync(as, ['-lib', 'LIBC', '-o', 'PRIMES.EXE', 'CRT0.S', 'PRIMES.S'], { cwd: tmp, encoding: 'utf8' });
    let out = '';
    if (r3.status === 0) {
      const exe = fs.readFileSync(path.join(tmp, 'PRIMES.EXE'));
      const load = exe.readUInt32LE(4), entry = exe.readUInt32LE(8), size = exe.readUInt32LE(12);
      const kernel = fs.readFileSync(path.join(__dirname, 'cctest.js'), 'utf8').match(/const KERNEL = `([\s\S]*?)`;/)[1];
      const img = new Uint8Array(load + size);
      img.set(assemble(kernel.replace('JMP32 start', 'JMP32 0x' + entry.toString(16))).image, 0);
      img.set(exe.subarray(16, 16 + size), load);
      const cpu = new CPU({ xlen: 32, onTx: (b) => { out += String.fromCharCode(b); } });
      cpu.load(img);
      cpu.run(50_000_000);
    }
    const ok3 = /Total primes: 168/.test(out);
    results.push({ name: 'as -lib LIBC（primes.c）', ok: ok3, why: ok3 ? '' : (r3.stderr || out.slice(-200)).split('\n')[0] });
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return results;
}

if (require.main === module) {
  const results = run();
  if (!results) { console.log('gcc がないので飛ばす'); process.exit(0); }
  for (const r of results) console.log(`${r.ok ? 'ok' : 'NG'}  ${r.name} ${r.why}`);
  const ng = results.filter((r) => !r.ok).length;
  console.log(`${results.length - ng} / ${results.length} ok`);
  process.exit(ng ? 1 : 0);
}

module.exports = { run };
