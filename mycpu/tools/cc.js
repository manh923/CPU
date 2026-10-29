#!/usr/bin/env node
// C のプログラムを、この CPU の MyDOS 用 .EXE にする（PC の上で動かすドライバ）
//   node tools/cc.js prog.c [ほかの .c ...] -o PROG.EXE   … .EXE を作る（SDRAM の 0x1000000 から動く）
//   node tools/cc.js prog.c -S prog.asm                   … アセンブリ（ライブラリ込み）だけ出す
// コンパイラは cc/（chibicc をこの CPU 向けに改造したもの）。なければ make でビルドする（gcc が要る）。
// リンカの代わりに、crt0・プログラム・C ライブラリ（libc/）のアセンブリを 1 つにつなげてアセンブルする：
//   コードを前に、データを後ろにまとめ（codegen.c の「; @text」「; @data」で分ける）、
//   最後に __heap_start（malloc がここから後ろを使う）を置く。
//   使われない関数・変数は捨てる（codegen.c の「; @fn」「; @obj」で分けて、crt0 からたどれるものだけ残す）。
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

// コンパイルした結果を覚えておく（libc は何度もコンパイルするので）：パス・-I・更新時刻 → アセンブリ
const cache = new Map();
function compileCached(file, includes) {
  const key = [path.resolve(file), ...includes, fs.statSync(file).mtimeMs, fs.statSync(CC).mtimeMs].join('\0');
  if (!cache.has(key)) cache.set(key, compileFile(file, includes));
  return cache.get(key);
}

// アセンブリをコードとデータに分け、それぞれを関数・変数ごとのかたまりにする（codegen.c の「; @fn」「; @obj」）
//   かたまり = { name: 定義するラベル（先頭のものは null）, lines: [...] }
function split(asm) {
  const text = [{ name: null, lines: [] }], data = [{ name: null, lines: [] }];
  let cur = text;
  for (const line of asm.split('\n')) {
    if (line === '; @data') cur = data;
    else if (line === '; @text') cur = text;
    else if (line.startsWith('; @fn ') || line.startsWith('; @obj ')) cur.push({ name: line.split(' ')[2], lines: [] });
    else if (line.startsWith('; @common ')) data[0].lines.push(line);     // 残すかは後で決める
    else cur[cur.length - 1].lines.push(line);
  }
  return { text, data };
}

// 使われない関数・変数を捨てる（リンカの --gc-sections と同じ）。.s のファイルと名前のないかたまりから、
// たどれるラベルのものだけ残す
function gc(parts, roots) {
  const byName = new Map();
  for (const p of parts) for (const c of [...p.text, ...p.data]) if (c.name) byName.set(c.name, c);
  const keep = new Set();
  const refs = (lines) => {
    const out = [];
    for (const line of lines) {
      const code = line.replace(/;.*/, '');
      for (const m of code.matchAll(/[A-Za-z_][\w.]*/g)) if (byName.has(m[0])) out.push(m[0]);
    }
    return out;
  };
  const todo = [...roots];
  for (const p of parts) for (const c of [...p.text, ...p.data]) if (!c.name) todo.push(...refs(c.lines));
  while (todo.length) {
    const n = todo.pop();
    if (keep.has(n)) continue;
    keep.add(n);
    todo.push(...refs(byName.get(n).lines));
  }
  for (const p of parts) {
    p.text = p.text.filter((c) => !c.name || keep.has(c.name));
    p.data = p.data.filter((c) => !c.name || keep.has(c.name));
  }
  return keep;
}

// .c の並び → プログラム全体のアセンブリ（crt0・C ライブラリ込み）
//   opts.includes はインクルードを探すフォルダ。opts.gc = false なら、使わない関数・変数も捨てない
//   （disk/as.c は捨てないので、比べるテストはこれを使う）。
//   opts.lib なら C ライブラリだけ（crt0 なし、捨てない、最後は ___heap_start でなく ___libc_end）：buildLib が使う
function buildAsm(files, opts = {}) {
  const includes = opts.includes || [];
  const libc = fs.readdirSync(LIBC).filter((f) => f.endsWith('.c')).sort().map((f) => path.join(LIBC, f));
  ensureCompiler();
  const parts = [...files, ...libc].map((f) => ({ name: path.relative(ROOT, f), ...split(compileCached(f, includes)) }));
  // crt0.s を先頭に、ほかの libc/*.s（setjmp など）はその後ろに
  const asms = fs.readdirSync(LIBC).filter((f) => f.endsWith('.s') && f !== 'crt0.s').sort();
  const asmText = [...(opts.lib ? [] : ['crt0.s']), ...asms].map((f) => fs.readFileSync(path.join(LIBC, f), 'utf8'));
  let keep = null;
  if (opts.gc !== false && !opts.lib) {
    const roots = [];
    for (const t of asmText) for (const m of t.replace(/;.*/g, '').matchAll(/[A-Za-z_][\w.]*/g)) roots.push(m[0]);
    keep = gc(parts, roots.filter((n) => parts.some((p) => [...p.text, ...p.data].some((c) => c.name === n))));
  }
  const join = (chunks) => chunks.map((c) => c.lines.join('\n')).join('\n');
  for (const p of parts) {
    p.text = join(p.text);
    p.data = join(p.data);
  }
  const out = [
    `; ${files.map((f) => path.basename(f)).join(' ')} — tools/cc.js が作ったアセンブリ（C ライブラリ込み）`,
    `        .org 0x${BASE.toString(16)}`,
    ...asmText,
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
  for (const [name, c] of common) if (!defined.has(name) && (!keep || keepCommon(name, parts))) out.push(`        .align ${c.align}`, `${name}:`, `        .space ${c.size}`);
  if (opts.lib) out.push('        .align 64', '___libc_end:', '');
  else out.push('        .align 8', '___heap_start:', '');
  return out.join('\n');
}

// 先にアセンブルしておく C ライブラリ（AS -lib LIBC 用）：0x1000000 から置く LIBC.BIN と、名前と番地の表 LIBC.SYM
//   LIBC.SYM：「@base 16 進」「@end 16 進」（LIBC.BIN の終わり。プログラムはここから）、
//     「@chunk 始め 終わり 番号 …」（関数・変数・.s のファイルごとのかたまりの番地の範囲と、それが使うかたまりの番号。
//      番号は @chunk の行の順に 0 から。AS は、プログラムが使うかたまりだけを .EXE に入れる）、
//     「名前 16 進」（大域の名前だけ）
function buildLib() {
  const { assemble } = require('../lib/assembler.js');
  const { asm, chunks } = buildLibAsm();
  const r = assemble(asm);
  const end = Number(r.symbols.get('___libc_end'));
  const bin = Buffer.from(r.image.subarray(BASE, end));
  const lines = ['; LIBC.SYM — LIBC.BIN（C ライブラリ）の名前と番地（tools/cc.js が作る。AS -lib LIBC が読む）',
    `@base ${BASE.toString(16)}`, `@end ${end.toString(16)}`];

  // かたまりの番地の範囲と、使うかたまり
  const owner = new Map();
  chunks.forEach((c, i) => { for (const n of c.names) owner.set(n, i); });
  chunks.forEach((c, i) => {
    const start = Number(r.symbols.get(`L__c.${i}`));
    const stop = i + 1 < chunks.length ? Number(r.symbols.get(`L__c.${i + 1}`)) : end;
    const deps = new Set();
    for (const m of c.text.replace(/;.*/g, '').matchAll(/[A-Za-z_][\w.]*/g)) {
      const j = owner.get(m[0]);
      if (j !== undefined && j !== i) deps.add(j);
    }
    lines.push(['@chunk', start.toString(16), stop.toString(16), ...[...deps].sort((a, b) => a - b)].join(' '));
  });

  for (const [name, v] of [...r.symbols].sort((a, b) => Number(a[1]) - Number(b[1])))
    if (name.startsWith('_') && !name.includes('.') && name !== '___libc_end') lines.push(`${name} ${Number(v).toString(16)}`);
  return { bin, sym: lines.join('\r\n') + '\r\n' };
}

// C ライブラリだけのアセンブリ（buildLib 用）。かたまり（関数・変数・.s のファイル・初期値なしの大域変数）の前に
// 「L__c.番号:」を置き、かたまりの一覧 { names: 定義する名前, text } も返す
function buildLibAsm() {
  ensureCompiler();
  const libc = fs.readdirSync(LIBC).filter((f) => f.endsWith('.c')).sort().map((f) => path.join(LIBC, f));
  const parts = libc.map((f) => split(compileCached(f, [])));
  const asms = fs.readdirSync(LIBC).filter((f) => f.endsWith('.s') && f !== 'crt0.s').sort();
  const chunks = [];
  const out = ['; C ライブラリ — tools/cc.js が作ったアセンブリ（LIBC.BIN 用）', `        .org 0x${BASE.toString(16)}`];
  const add = (names, text) => {
    out.push(`L__c.${chunks.length}:`, text);
    chunks.push({ names, text });
  };
  for (const f of asms) {
    const t = fs.readFileSync(path.join(LIBC, f), 'utf8');
    add([...t.matchAll(/^([A-Za-z_]\w*):/gm)].map((m) => m[1]), t);
  }
  for (const p of parts) for (const c of p.text) add(c.name ? [c.name] : [], c.lines.join('\n'));
  out.push('', '; ---- データ ----', '        .align 64');
  for (const p of parts) for (const c of p.data) add(c.name ? [c.name] : [], c.lines.join('\n'));
  // 初期値なしの大域変数：どこにも定義がなければ、1 つだけ置く
  const defined = new Set();
  for (const c of chunks) for (const m of c.text.matchAll(/^([A-Za-z_][\w.]*):/gm)) defined.add(m[1]);
  const common = new Map();
  for (const c of chunks) {
    for (const m of c.text.matchAll(/^; @common (\S+) (\d+) (\d+)$/gm)) {
      const k = common.get(m[1]) || { size: 0, align: 4 };
      common.set(m[1], { size: Math.max(k.size, +m[2]), align: Math.max(k.align, +m[3]) });
    }
  }
  for (const [name, c] of common)
    if (!defined.has(name)) add([name], `        .align ${c.align}\n${name}:\n        .space ${c.size}`);
  out.push('        .align 64', '___libc_end:', '');
  return { asm: out.join('\n'), chunks };
}

// 初期値なしの大域変数が、残したコードかデータから使われているか
function keepCommon(name, parts) {
  const re = new RegExp(`(^|[^\\w.])${name.replace(/\./g, '\\.')}($|[^\\w.])`, 'm');
  return parts.some((p) => re.test((p.text + '\n' + p.data).replace(/;.*/g, '')));
}

// MyDOS の 8.3 の名前に縮める（libc の fopen と同じ規則：名前 8 文字・拡張子 3 文字まで）
function dosName(name) {
  const m = /^([^.]*)(?:\.(.*))?$/.exec(name);
  return (m[1].slice(0, 8) + (m[2] !== undefined ? '.' + m[2].slice(0, 3) : '')).toUpperCase();
}

// MyDOS の上の C コンパイラ一式（disk/ のカードに入れる）：
//   CC.EXE（cc/ を この CPU 向けにコンパイルしたもの。アセンブル済みのバイト列）、CRT0.S と LIBC.S（リンク用。
//   libc をコンパイルしてつないだもの）、LIBC.BIN・LIBC.SYM（LIBC.S を先にアセンブルしたもの。AS -lib LIBC で速くつなぐ）、ヘッダ（cc/include・libc/include・libc/include/sys を 8.3 の名前で）、
//   chibicc のソース（セルフホスト用。preprocess.c → PREPROCE.C）
let compilerCache = null;
function compilerFiles() {
  const srcs = fs.readdirSync(CC_DIR).filter((f) => /\.[ch]$/.test(f)).sort();
  const libs = fs.readdirSync(LIBC).filter((f) => /\.[cs]$/.test(f)).sort();
  const incs = ['cc/include', 'libc/include', 'libc/include/sys'].map((d) => path.join(ROOT, d));
  const all = [...srcs.map((f) => path.join(CC_DIR, f)), ...libs.map((f) => path.join(LIBC, f)),
    ...incs.flatMap((d) => fs.readdirSync(d).filter((f) => f.endsWith('.h')).map((f) => path.join(d, f)))];
  const stamp = all.map((f) => fs.statSync(f).mtimeMs).join(',');
  if (compilerCache && compilerCache.stamp === stamp) return compilerCache.files;

  const { makeFile } = require('../lib/disk.js');
  const out = [];
  const cc = buildAsm(srcs.filter((f) => f.endsWith('.c')).map((f) => path.join(CC_DIR, f)));
  out.push({ name: 'CC.EXE', contents: Buffer.from(makeFile('cc.exe.asm', cc).data) });
  out.push({ name: 'CRT0.S', contents: fs.readFileSync(path.join(LIBC, 'crt0.s')) });
  const libc = [];
  for (const f of libs) if (f.endsWith('.s') && f !== 'crt0.s') libc.push(fs.readFileSync(path.join(LIBC, f), 'utf8'));
  for (const f of libs) if (f.endsWith('.c')) libc.push(compileCached(path.join(LIBC, f), []));
  out.push({ name: 'LIBC.S', contents: Buffer.from(libc.join('\n')) });
  const lib = buildLib();
  out.push({ name: 'LIBC.BIN', contents: lib.bin }, { name: 'LIBC.SYM', contents: Buffer.from(lib.sym) });
  const seen = new Set(out.map((f) => f.name));
  for (const d of incs) {
    for (const f of fs.readdirSync(d).filter((f) => f.endsWith('.h')).sort()) {
      const n = dosName(f);
      if (seen.has(n)) throw new Error(`カードの名前がぶつかる：${n}`);
      seen.add(n);
      out.push({ name: n, contents: fs.readFileSync(path.join(d, f)) });
    }
  }
  for (const f of srcs) {
    const n = dosName(f);
    if (seen.has(n)) throw new Error(`カードの名前がぶつかる：${n}`);
    seen.add(n);
    out.push({ name: n, contents: fs.readFileSync(path.join(CC_DIR, f)) });
  }
  compilerCache = { stamp, files: out };
  return out;
}

// SD カードの中身のもと（mkdisk・sim.js・テスト用）：フォルダのファイルを読み、
// NAME.c があればコンパイルした NAME.exe.asm も足す（.c もそのまま入れる）。.asm は文字列、ほかはバイト列。
// リポジトリの disk/ なら、C コンパイラ一式（compilerFiles）も入れる（opts.compiler = false で入れない）
function diskSources(dir, opts = {}) {
  const out = [];
  for (const name of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, name);
    if (!fs.statSync(file).isFile()) continue;
    out.push({ name, contents: /\.asm$/i.test(name) ? fs.readFileSync(file, 'utf8') : fs.readFileSync(file) });
    if (/\.c$/i.test(name)) out.push({ name: name.replace(/\.c$/i, '.exe.asm'), contents: buildAsm([file]) });
  }
  if (opts.compiler !== false && path.resolve(dir) === path.join(ROOT, 'disk')) {
    const names = new Set(out.map((f) => dosName(f.name.replace(/\.(exe|com|sys)\.asm$/i, '.$1'))));
    for (const f of compilerFiles()) {
      if (names.has(f.name)) throw new Error(`disk/ のファイルと名前がぶつかる：${f.name}`);
      out.push(f);
    }
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

module.exports = { buildAsm, buildLib, buildLibAsm, diskSources, compilerFiles, dosName, compileFile, CcError };
