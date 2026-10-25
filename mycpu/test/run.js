#!/usr/bin/env node
// テスト一式：node test/run.js
//   1. 自動生成ファイルが opcodes.csv・examples と合っているか
//   2. アセンブラ（全命令の組み立て、エラーの出し方）
//   3. シミュレータで例題を動かし、出力を確かめる
//   4. iverilog があれば、同じ例題を Verilog でも動かし、UART 出力・レジスタ・画面がシミュレータと一致するか
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const isa = require('../lib/isa.js');
const CPU = require('../lib/cpu.js');
const video = require('../lib/video.js');
const { assemble, toReadmemh, AsmError } = require('../lib/assembler.js');

const ROOT = path.join(__dirname, '..');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'mycpu-test-'));
let failed = 0, passed = 0;

function check(name, ok, detail) {
  if (ok) { passed++; console.log('  ok   ' + name); }
  else { failed++; console.log('  NG   ' + name + (detail ? '\n       ' + String(detail).replace(/\n/g, '\n       ') : '')); }
}

function src(name) { return fs.readFileSync(path.join(ROOT, 'examples', name), 'utf8'); }

// シミュレータで動かす
function runSim(source, opts = {}) {
  let out = '';
  const cpu = new CPU({ xlen: opts.xlen || 32, onTx: (b) => { out += String.fromCharCode(b); } });
  cpu.load(assemble(source).image);
  if (opts.input) cpu.pushRx(Buffer.from(opts.input, 'latin1'));
  cpu.run(opts.max || 5_000_000);
  return { cpu, out };
}

// ---- 1 ----
console.log('自動生成ファイル');
{
  const r = spawnSync(process.execPath, [path.join(ROOT, 'tools/gen.js'), '--check'], { encoding: 'utf8' });
  check('lib/opcodes.js・lib/examples.js・rtl/opcodes.vh が最新', r.status === 0, r.stderr);
}

// ---- 2 ----
console.log('アセンブラ');
{
  // 全命令：オペランドに合うレジスタを入れて組み立て、ヘッダのオペコードを確かめる
  const pick = { data32: 'r17', data64: 'r33', p: 'p2', addr: 'r18', r32: 'r19', r64: 'r34' };
  let bad = [];
  for (const row of isa.OPCODES) {
    const ops = row.spec.map((s) => {
      if (s.cls === 'imm') return '0x1234';
      if (s.cls === 'data') return row.wbits === 64 ? pick.data64 : pick.data32;
      return pick[s.cls];
    });
    try {
      const img = assemble(`${row.mnemonic} ${ops.join(', ')}`).image;
      const h = img[0] | (img[1] << 8) | (img[2] << 16) | (img[3] << 24);
      if ((h & 0x3fff) !== row.opcode || img.length !== row.length) bad.push(row.mnemonic);
    } catch (e) { bad.push(row.mnemonic + ': ' + e.message); }
  }
  check(`全 ${isa.OPCODES.length} 命令を組み立てられる`, bad.length === 0, bad.join('\n'));

  const enc = assemble('ADDI32 sp, r0, 0x28000\nBR32 p1, 0\nSEL32 r17, r16, r18, p3\nSTORE8_32 r16, r0, 0x10000').image;
  const words = [];
  for (let i = 0; i < enc.length; i += 4) words.push((enc[i] | (enc[i + 1] << 8) | (enc[i + 2] << 16) | (enc[i + 3] << 24)) >>> 0);
  check('フィールドの位置（SP・BR の p は rs1 欄・SEL の p は即値・ストアの rs2）',
    JSON.stringify(words) === JSON.stringify([0x000C4045, 0x28000, 0x00100055, 0, 0x4904460D, 3, 0x40000411, 0x10000]),
    words.map((w) => w.toString(16)).join(' '));

  const errs = (s) => { try { assemble(s); return []; } catch (e) { if (e instanceof AsmError) return e.errors.map((x) => x.message); throw e; } };
  check('幅の合わないレジスタはエラー', /64bit|32bit/.test(errs('ADDR32 r32, r16, r16').join()));
  check('PC への書き込みはエラー', /PC/.test(errs('ADDI32 pc, r0, 0').join()));
  check('予備レジスタはエラー', /予備/.test(errs('ADDR32 r8, r16, r16').join()));
  check('1bit レジスタ以外を p に使うとエラー', errs('CMPEQR32 r16, r17, r18').length === 1);
  check('知らない命令はエラー', /知らない/.test(errs('FOO r1').join()));
  check('即値が幅に入らないとエラー', errs('ADDI32 r16, r0, 0x100000000').length === 1);
  check('未定義のラベルはエラー', /未定義/.test(errs('JMP32 nowhere').join()));
  const ph = assemble('JMP32 b\n.align 16\nimg:\n.phase 0x20000\nb: JMP32 b\n.dephase\nimg_end:\n');
  check('.phase：置く場所はそのまま、ラベルは写した先の番地',
    ph.symbols.get('img') === 0x10n && ph.symbols.get('b') === 0x20000n && ph.symbols.get('img_end') === 0x18n &&
    ph.image[4] === 0x00 && ph.image[6] === 0x02 && ph.image[0x14] === 0x00 && ph.image[0x16] === 0x02);
  check('.phase：16 バイト単位でそろっていないとエラー', /16/.test(errs('NOP\n.phase 0x20000\n').join()));
  const lab = assemble('.byte 1\nx: NOP\ny: .byte 2\n').symbols;
  check('命令の前のラベルは 4 バイト境界', lab.get('x') === 4n && lab.get('y') === 8n);
  const loc = assemble('a:\n.l: NOP\nb:\n.l: JMP32 .l\nJMP32 a.l').image;
  check('ローカルラベル（.l）は直前のラベルの中だけ', loc[8] === 4 && loc[16] === 0);
}

// ---- 3 ----
console.log('シミュレータ');
const cases = [];
{
  let r = runSim(src('hello.asm'));
  check('hello：UART', r.out === 'Hello, MyCPU!\r\n', JSON.stringify(r.out));
  check('hello：画面（2 行目の 3 文字目から）', video.text(r.cpu.vram) === '\n  Hello, MyCPU!', JSON.stringify(video.text(r.cpu.vram)));

  r = runSim(src('selftest32.asm'));
  check('selftest32（32bit CPU）', r.out === 'selftest32: PASS\n', r.out);
  r = runSim(src('selftest32.asm'), { xlen: 64 });
  check('selftest32 を 64bit CPU でも（上位互換）', r.out === 'selftest32: PASS\n', r.out);
  r = runSim(src('selftest64.asm'), { xlen: 64 });
  check('selftest64（64bit CPU）', r.out === 'selftest64: PASS\n', r.out);
  r = runSim(src('selftest64.asm'));
  check('32bit CPU は 64bit 命令で止まる', r.cpu.halted.kind === 'illegal', JSON.stringify(r.cpu.halted));

  r = runSim(src('trap.asm'));
  check('trap：例外・ユーザーモード・タイマー割り込み',
    r.out === 'reset\nsyscall\ndivzero\nalign\nuser\nsyscall\npriv\ntimer\ndone\n', JSON.stringify(r.out));

  r = runSim(src('trap.asm'), { xlen: 64 });
  check('trap を 64bit CPU でも（割り込みの印は bit31。6.3）',
    r.out === 'reset\nsyscall\ndivzero\nalign\nuser\nsyscall\npriv\ntimer\ndone\n', JSON.stringify(r.out.slice(0, 120)));

  r = runSim(src('fib.asm'), { max: 10_000_000 });
  check('fib：再帰とスタック', r.out.endsWith('fib(19) = 4181\r\nfib(20) = 6765\r\n') && r.cpu.halted.kind === 'hlt', r.out.slice(-40));

  const input = 'abc\rde\bf\r\nxyz\x04';
  r = runSim(src('console.asm'), { input });
  check('console：キー入力 → 画面', video.text(r.cpu.vram).split('\n').slice(2).join('|') === 'abc|df|xyz', video.text(r.cpu.vram));
  let many = '';
  for (let i = 1; i <= 50; i++) many += 'line' + i + '\r';
  const r2 = runSim(src('console.asm'), { input: many + '\x04', max: 20_000_000 });
  const lines = video.text(r2.cpu.vram).split('\n');
  check('console：画面の下まで来たらスクロール', lines[1] === 'line8' && lines[43] === 'line50', lines.slice(0, 3).join('|'));

  r = runSim('ADDI32 r16, r0, 0x10001\nLOAD32_32 r17, r16, 0\nHLT');
  check('整列していない読み出しは例外（EVEC = 0 へ）', r.cpu.cause === 1n);
  r = runSim('ADDI32 r16, r0, 0\nSTORE32_32 r16, r0, 0x100\nHLT');
  check('ROM への書き込みは止まる', r.cpu.halted.kind === 'fault');
  check('32bit CPU で r32〜r47 をアドレスに使うと止まる（アセンブルはできる）',
    runSim('LOAD32_32 r17, r32, 0\nHLT').cpu.halted.kind === 'illegal');

  // MyDOS：BIOS → ROM から写して起動 → コマンド
  const dosInput = ' ver\rdir\rtype readme.txt\rtype nofile\rfoo\recho  Hi   there\rcolor 1e\rmem\rled 2a\rshutdown\r';
  r = runSim(src('mydos.asm'), { input: dosInput, max: 20_000_000 });
  const scr = video.text(r.cpu.vram);
  check('mydos：BIOS からシャットダウンまで', r.cpu.halted && r.cpu.halted.kind === 'hlt' &&
    r.out.includes('Memory Test : 32 KB OK') && r.out.includes('MyDOS Version 1.0 (MyCPU-32)') &&
    r.out.includes('README   TXT') && r.out.includes('Bad command or file name') && r.out.includes('File not found') &&
    r.out.includes('Hi   there\r\n') && r.out.includes(` ${0x27000 - Number(assemble(src('mydos.asm')).symbols.get('os_end'))} bytes free`) && r.out.includes("safe to turn off"),
  r.out.slice(-300));
  check('mydos：COLOR と LED', r.cpu.vram[1] === 0x0E && r.cpu.led === 0x2a, `attr=${r.cpu.vram[1]} led=${r.cpu.led}`);
  check('mydos：画面にも出ている', scr.includes("It's now safe to turn off your computer."), scr.slice(0, 200));

  // UART から起動：U → 'MC' + 長さ + プログラム → 動いて、キーで再起動 → MyDOS → シャットダウン
  const app = assemble(fs.readFileSync(path.join(ROOT, 'examples/uartboot/hello_uart.asm'), 'utf8')).image.subarray(0x20000);
  const frame = Buffer.concat([Buffer.from('MC', 'latin1'), Buffer.from(new Uint32Array([app.length]).buffer), Buffer.from(app)]);
  const bootInput = Buffer.concat([Buffer.from('u', 'latin1'), frame, Buffer.from('x shutdown\r', 'latin1')]).toString('latin1');
  r = runSim(src('mydos.asm'), { input: bootInput, max: 20_000_000 });
  check('mydos：UART から起動したプログラムが動き、再起動して MyDOS へ',
    r.out.includes('Loaded ' + app.length + ' bytes') && r.out.includes('1 4 9 16 25 36 49 64 81 100') &&
    r.out.split('MyCPU BIOS').length === 3 && r.out.includes("safe to turn off"), r.out.slice(-400));

  cases.push(
    { name: 'mydos', file: 'mydos.asm', input: bootInput, max: 40_000_000 },
    { name: 'hello', file: 'hello.asm' },
    { name: 'selftest32', file: 'selftest32.asm' },
    { name: 'trap', file: 'trap.asm', regs: false },
    { name: 'fib', file: 'fib.asm', max: 60_000_000 },
    { name: 'console', file: 'console.asm', input },
    { name: 'colors', file: 'colors.asm', ppm: true },
  );
}

// ---- 4 ----
console.log('Verilog（iverilog）');
if (spawnSync('iverilog', ['-V']).error) {
  console.log('  --   iverilog がないので飛ばす');
} else {
  const rtl = ['rtl/cpu.v', 'rtl/soc.v', 'rtl/uart.v', 'rtl/video.v'].map((f) => path.join(ROOT, f));
  const p = (f) => path.join(ROOT, f);

  execFileSync('iverilog', ['-g2012', '-o', path.join(TMP, 'tmds.vvp'), p('tb/tb_tmds.v'), p('rtl/tmds.v')]);
  const tm = execFileSync('vvp', ['-n', path.join(TMP, 'tmds.vvp')], { encoding: 'utf8' });
  check('TMDS 符号器：元に戻せて、直流の偏りが小さい', /tb_tmds: 0 件 NG/.test(tm), tm.trim());

  const top = spawnSync('iverilog', ['-g2012', '-I', p('rtl'), '-o', path.join(TMP, 'top.vvp'), '-s', 'top_tangnano20k',
    p('rtl/gowin/top_tangnano20k.v'), ...rtl, p('rtl/tmds.v'), p('tb/gowin_stubs.v')], { encoding: 'utf8' });
  check('Tang Nano 20K のトップがコンパイルできる（Gowin 部品は代わりのモジュール）', top.status === 0, top.stderr);

  for (const c of cases) {
    const base = path.join(TMP, c.name);
    const source = src(c.file);
    const { image } = assemble(source);
    fs.writeFileSync(base + '.hex', toReadmemh(image, isa.MAP.ROM_SIZE / 4));

    // シミュレータ側の答え
    const sim = runSim(source, { input: c.input, max: 20_000_000 });
    // Verilog 側
    execFileSync('iverilog', ['-g2012', '-DMYCPU_SIM', '-I', path.join(ROOT, 'rtl'), '-o', base + '.vvp',
      `-Ptb.ROM_HEX="${base}.hex"`, `-Ptb.FONT_HEX="${path.join(ROOT, 'font/font8x16.hex')}"`,
      path.join(ROOT, 'tb/tb_soc.v'), ...rtl]);
    const args = ['-n', base + '.vvp', `+uart=${base}.uart`, `+regs=${base}.regs`, `+max=${c.max || 20_000_000}`];
    if (c.input) { fs.writeFileSync(base + '.rx', Buffer.from(c.input, 'latin1')); args.push(`+rx=${base}.rx`); }
    if (c.ppm) args.push(`+ppm=${base}.ppm`);
    const log = execFileSync('vvp', args, { encoding: 'utf8' });
    const halted = /停止 halt_code=1/.test(log);
    const out = fs.readFileSync(base + '.uart', 'latin1');
    check(`${c.name}：HLT で止まる`, halted, log.trim());
    check(`${c.name}：UART 出力が一致`, out === sim.out, JSON.stringify(out.slice(0, 200)) + '\n≠ ' + JSON.stringify(sim.out.slice(0, 200)));
    if (c.regs !== false) {
      const regs = fs.readFileSync(base + '.regs', 'utf8');
      check(`${c.name}：レジスタが一致`, regs === sim.cpu.dumpRegs(), regs + '≠\n' + sim.cpu.dumpRegs());
    }
    if (c.ppm) {
      const want = Buffer.concat([Buffer.from(`P6\n${video.WIDTH} ${video.HEIGHT}\n255\n`), Buffer.from(video.render(sim.cpu.vram))]);
      const got = fs.readFileSync(base + '.ppm');
      let diff = -1;
      for (let i = 0; i < want.length; i++) if (want[i] !== got[i]) { diff = i; break; }
      check(`${c.name}：表示回路の 1 フレームがシミュレータの絵と一致`, got.length === want.length && diff < 0,
        `長さ ${got.length} / ${want.length}、最初の違い ${diff}`);
    }
  }
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${passed} 件 ok、${failed} 件 NG`);
process.exit(failed ? 1 : 0);
