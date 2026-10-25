#!/usr/bin/env node
// C のプログラムを、この CPU の MyDOS 用 .EXE にする（PC の上で動かすドライバ）
//   node tools/cc.js prog.c [ほかの .c ...] -o PROG.EXE   … .EXE を作る（SDRAM の 0x1000000 から動く）
//   node tools/cc.js prog.c -S prog.asm                   … アセンブリ（ライブラリ込み）だけ出す
// コンパイラは cc/（chibicc をこの CPU 向けに改造したもの）。なければ make でビルドする（gcc が要る）。
// リンカの代わりに、crt0・プログラム・C ライブラリ（libc/）のアセンブリを 1 つにつなげてアセンブルする：
//   コードを前に、データを後ろにまとめ（codegen.c の「; @text」「; @data」で分ける）、
//   最後に __heap_start（malloc がここから後ろを使う）を置く。
// require して使う：buildAsm(.c のパスの並び) → アセンブリの文字列、diskSources(フォルダ) → mkdisk 用の並び
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const CC_DIR = path.join(ROOT, 'cc');
const CC = path.join(CC_DIR, 'chibicc');
const LIBC = path.join(ROOT, 'libc');
const BASE = 0x01000000;              // SDRAM（MyDOS が .EXE をここに読み込み、スタックも SDRAM の末尾に置く）

class CcError extends Error {}

// cc/chibicc がなければ（ソースより古ければ）ビルドする
function ensureCompiler() {
  const srcs = fs.readdirSync(CC_DIR).filter((f) => /\.[ch]$/.test(f)).map((f) => path.join(CC_DIR, f));
  const built = fs.existsSync(CC) ? fs.statSync(CC).mtimeMs : 0;
  if (srcs.some((f) => fs.statSync(f).mtimeMs > built)) {
    try {
      execFileSync('make', ['-C', CC_DIR, 'chibicc'], { stdio: ['ignore', 'ignore', 'pipe'] });
    } catch (e) {
      throw new CcError('cc/ のビルドに失敗（gcc と make が要る）\n' + (e.stderr || e.message));
    }
  }
}

// 1 つの .c をアセンブリにする。パスはリポジトリからの相対で渡す（ファイルの番号＝ラベルが、どの PC でも同じになるように）
function compileFile(file, includes = []) {
  ensureCompiler();
  const tmp = path.join(os.tmpdir(), `mycpu-cc-${process.pid}-${path.basename(file)}.s`);
  const rel = path.relative(ROOT, path.resolve(file));
  const inc = includes.map((d) => '-I' + (path.relative(ROOT, path.resolve(d)) || '.'));
  try {
    execFileSync(CC, ['-cc1', '-cc1-input', rel, '-cc1-output', tmp, ...inc, rel], { cwd: ROOT, stdio: ['ignore', 'ignore', 'pipe'] });
    return fs.readFileSync(tmp, 'utf8');
  } catch (e) {
    throw new CcError(String(e.stderr || e.message).trim());
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

// アセンブリをコードとデータに分ける
function split(asm) {
  const text = [], data = [];
  let cur = text;
  for (const line of asm.split('\n')) {
    if (line === '; @data') cur = data;
    else if (line === '; @text') cur = text;
    else cur.push(line);
  }
  return { text: text.join('\n'), data: data.join('\n') };
}

// .c の並び → プログラム全体のアセンブリ（crt0・C ライブラリ込み）。opts.includes はインクルードを探すフォルダ
function buildAsm(files, opts = {}) {
  const libc = fs.readdirSync(LIBC).filter((f) => f.endsWith('.c')).sort().map((f) => path.join(LIBC, f));
  const parts = [...files, ...libc].map((f) => ({ name: path.relative(ROOT, f), ...split(compileFile(f, opts.includes)) }));
  const out = [
    `; ${files.map((f) => path.basename(f)).join(' ')} — tools/cc.js が作ったアセンブリ（C ライブラリ込み）`,
    `        .org 0x${BASE.toString(16)}`,
    fs.readFileSync(path.join(LIBC, 'crt0.s'), 'utf8'),
  ];
  for (const p of parts) out.push(`; ---- ${p.name} ----`, p.text);
  out.push('', '; ---- データ ----', '        .align 64');
  for (const p of parts) out.push(`; ---- ${p.name} ----`, p.data);
  // 初期値なしの大域変数：どこにも定義がなければ、ここに 1 つだけ置く（大きさ・揃えはいちばん大きいもの）
  const defined = new Set();
  for (const p of parts) for (const m of (p.text + '\n' + p.data).matchAll(/^([A-Za-z_][\w.]*):/gm)) defined.add(m[1]);
  const common = new Map();
  for (const p of parts) {
    for (const m of p.data.matchAll(/^; @common (\S+) (\d+) (\d+)$/gm)) {
      const c = common.get(m[1]) || { size: 0, align: 4 };
      common.set(m[1], { size: Math.max(c.size, +m[2]), align: Math.max(c.align, +m[3]) });
    }
  }
  for (const [name, c] of common) if (!defined.has(name)) out.push(`        .align ${c.align}`, `${name}:`, `        .space ${c.size}`);
  out.push('        .align 8', '___heap_start:', '');
  return out.join('\n');
}

// SD カードの中身のもと（mkdisk・sim.js・テスト用）：フォルダのファイルを読み、
// NAME.c があればコンパイルした NAME.exe.asm も足す（.c もそのまま入れる）。.asm は文字列、ほかはバイト列
function diskSources(dir) {
  const out = [];
  for (const name of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, name);
    if (!fs.statSync(file).isFile()) continue;
    out.push({ name, contents: /\.asm$/i.test(name) ? fs.readFileSync(file, 'utf8') : fs.readFileSync(file) });
    if (/\.c$/i.test(name)) out.push({ name: name.replace(/\.c$/i, '.exe.asm'), contents: buildAsm([file]) });
  }
  return out;
}

function main(argv) {
  const inputs = [];
  let out = null, asmOut = null;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '-o') out = argv[++i];
    else if (argv[i] === '-S') asmOut = argv[++i];
    else if (!argv[i].startsWith('-')) inputs.push(argv[i]);
    else usage();
  }
  if (!inputs.length || (!out && !asmOut)) usage();
  let asm;
  try {
    asm = buildAsm(inputs);
  } catch (e) {
    if (!(e instanceof CcError)) throw e;
    console.error(e.message);
    process.exit(1);
  }
  if (asmOut) fs.writeFileSync(asmOut, asm);
  if (out) {
    const { makeFile } = require('../lib/disk.js');
    const { AsmError } = require('../lib/assembler.js');
    try {
      const f = makeFile(path.basename(out).replace(/\.exe$/i, '') + '.exe.asm', asm);
      fs.writeFileSync(out, f.data);
      console.log(`${out}: ${f.data.length} バイト`);
    } catch (e) {
      if (!(e instanceof AsmError)) throw e;
      for (const err of e.errors.slice(0, 10)) console.error(`${err.line}: ${err.message}`);
      process.exit(1);
    }
  }
}

function usage() {
  console.error('使い方: node tools/cc.js prog.c [ほかの .c ...] -o PROG.EXE [-S prog.asm]');
  process.exit(2);
}

if (require.main === module) main(process.argv);

module.exports = { buildAsm, diskSources, compileFile, CcError };
