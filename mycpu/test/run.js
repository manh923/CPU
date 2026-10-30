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
const SDCard = require('../lib/sdcard.js');
const fat = require('../lib/fat.js');
const { makeDisk, makeFile } = require('../lib/disk.js');

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
  const trace = opts.trace ? [] : null;
  const cpu = new CPU({ xlen: opts.xlen || 32, onTx: (b) => { out += String.fromCharCode(b); }, sd: opts.disk ? new SDCard(opts.disk) : null,
    trace: trace ? (pc) => trace.push(Number(pc)) : null });
  cpu.load(assemble(source).image);
  if (opts.input) cpu.pushRx(Buffer.from(opts.input, 'latin1'));
  cpu.run(opts.max || 5_000_000);
  return { cpu, out, trace };
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

  {
    const c = new CPU({});
    const ok = c.load(assemble(fs.readFileSync(path.join(ROOT, 'examples/uartboot/hello_uart.asm'), 'utf8')).image);
    check('.org 0x20000 のプログラムも読み込める（すき間は飛ばす）。番地 0 が空なのも分かる', ok === false && c.ram[0] !== 0);
    let msg = '';
    try { new CPU({}).load(assemble('.org 0x8000\n.word 1').image); } catch (e) { msg = e.message; }
    check('メモリのない番地に中身があればエラー', /0x8000/.test(msg), msg);
  }
  r = runSim('ADDI32 r16, r0, 0x10001\nLOAD32_32 r17, r16, 0\nHLT');
  check('整列していない読み出しは例外（EVEC = 0 へ）', r.cpu.cause === 1n);
  r = runSim('ADDI32 r16, r0, 0\nSTORE32_32 r16, r0, 0x100\nHLT');
  check('ROM への書き込みは止まる', r.cpu.halted.kind === 'fault');
  check('32bit CPU で r32〜r47 をアドレスに使うと止まる（アセンブルはできる）',
    runSim('LOAD32_32 r17, r32, 0\nHLT').cpu.halted.kind === 'illegal');

  // ---- BIOS と MyDOS ----
  const nl = (t) => t.replace(/\n/g, '\r\n');
  const bios = src('bios.asm');
  const biosImage = assemble(bios).image;
  check('BIOS は ROM（16KB）に収まる', biosImage.length <= isa.MAP.ROM_SIZE, biosImage.length);
  const diskSources = require('../tools/cc.js').diskSources(path.join(ROOT, 'disk'));   // primes.c は PRIMES.EXE にも
  const files = diskSources.map((x) => makeFile(x.name, x.contents));
  const dosSym = assemble(fs.readFileSync(path.join(ROOT, 'disk/mydos.sys.asm'), 'utf8')).symbols;
  check('MYDOS.SYS（変数も含めて）は 0x26000 より前に収まる', Number(dosSym.get('bss_end')) <= 0x26000, dosSym.get('bss_end'));
  check('mkdisk：MZ ヘッダの .EXE、.COM、0x20000 からの .SYS',
    files.some((f) => f.name === 'HELLO.EXE' && f.data[0] === 0x4D && f.data[1] === 0x5A) && files.some((f) => f.name === 'KITT.COM') &&
    files.some((f) => f.name === 'MYDOS.SYS' && f.data.length > 10000));

  // カードなし：BIOS が MYDOS.SYS を探せず "Non-System disk"
  r = runSim(bios, { input: ' ', max: 5_000_000 });
  check('BIOS（カードなし）：メモリテスト 40KB、Non-System disk でキーを待つ', r.out.includes('Memory Test : 40 KB OK') &&
    r.out.includes('SD card     : not found') && r.out.includes('Non-System disk or disk error'), r.out.slice(-300));

  // カードの中身はあるが MYDOS.SYS がない
  r = runSim(bios, { input: ' ', disk: makeDisk(diskSources.filter((x) => !/mydos/.test(x.name))), max: 5_000_000 });
  check('BIOS：MYDOS.SYS のないカードも Non-System disk', r.out.includes('SD card     : SDHC/SDXC') && r.out.includes('Non-System disk'), r.out.slice(-200));

  const readme = fs.readFileSync(path.join(ROOT, 'disk/README.TXT'), 'latin1');
  const session = ' dir\rtype readme.txt\rhello\rhello claude\rfib 12\rkitt\r crash\rbig\rprimes\rtype nofile.txt\rtype\rver\rcolor 1e\rled 2a\r' +
    'copy con note.txt\rHello from MyDOS!\rSecond lline\b\b\b\b\bline\r\x1a\rcopy note.txt copy.txt\rren copy.txt renamed.txt\r' +
    'dir > list.txt\rfib 3 >> list.txt\rtoupper readme.txt up.txt\rdel note.txt\rdel nofile\rren renamed.txt hello.exe\r' +
    'type list.txt\rlibtest\r' +
    // EDIT：2 行打ち、↑・Home で 1 行目の頭へ戻って足し、Ctrl-S で保存、Ctrl-X で終わる
    'edit memo.txt\rHello EDIT!\rsecond line\x1b[A\x1b[H>> \x13\x18type memo.txt\rdel memo.txt\r' +
    // AS：MyDOS の上でアセンブルして実行
    'as -o hi2.exe hi.s\rhi2 MyCPU\rdel hi2.exe\r' +
    'demo\rshutdown\r';
  // C ライブラリのテスト（test/libtest.c）は、このセッションのカードにだけ入れる
  const libtest = { name: 'libtest.exe.asm', contents: require('../tools/cc.js').buildAsm([path.join(ROOT, 'test/libtest.c')]) };
  const hiS = { name: 'HI.S', contents: fs.readFileSync(path.join(ROOT, 'disk/hello.exe.asm')) };
  const mtoolsOk = !spawnSync('fsck.fat', ['--help']).error && !spawnSync('mcopy', ['--version']).error;
  const env = { ...process.env, MTOOLS_SKIP_CHECK: '1' };
  for (const type of ['fat16', 'fat32']) {
    const disk = makeDisk([...diskSources, libtest, hiS], { type });
    r = runSim(bios, { input: session, disk, max: 400_000_000 });
    const o = r.out;
    check(`MyDOS（${type}）：SD カードの MYDOS.SYS から起動、AUTOEXEC.BAT`, o.includes('Starting MyDOS') && o.includes('MyDOS Version 3.0') &&
      o.includes(nl('Welcome to MyDOS 3.0. Drive C: is the SD card.\n')), o.slice(0, 1500));
    check(`MyDOS（${type}）：DIR・TYPE`, o.includes(nl('HELLO    EXE       218 10-25-26  12:00p\n')) &&
      o.includes(nl('C:\\>type readme.txt\n' + readme)), o.slice(o.indexOf('C:\\>dir'), o.indexOf('C:\\>dir') + 900));
    check(`MyDOS（${type}）：ユーザーモードのプログラム（SYSCALL）`, o.includes(nl('Hello, World!\n')) && o.includes(nl('Hello, claude!\n')) &&
      o.includes(nl('fib(12) = 144\n')) && o.includes('LED chaser'), '');
    check(`MyDOS（${type}）：SDRAM に読み込む .EXE（スタックも SDRAM）`,
      o.includes(nl('Hello from SDRAM! PC = 01000024, SP = 017DFFF8\nRecursion depth: 10000\n')), '');
    check(`MyDOS（${type}）：C で書いたプログラム（PRIMES.EXE、cc/ と libc/ で作る）`,
      o.includes(nl('=== MyCPU Prime Search ===\nSearching primes from 2 to 1000...\nFound: 10 primes\n')) &&
      o.includes(nl('Found: 160 primes\nSearch complete!\nTotal primes: 168\n')), '');
    check(`MyDOS（${type}）：C ライブラリ（test/libtest.c：ファイル・書式・long long・setjmp など）`,
      o.includes(nl('libtest: 0 NG\n')),
      o.slice(o.indexOf('C:\\>libtest'), o.indexOf('libtest: ') + 20));
    check(`MyDOS（${type}）：EDIT（C で書いたエディタ。矢印キー・保存）`,
      o.includes(nl('C:\\>type memo.txt\n>> Hello EDIT!\nsecond line\n')), o.slice(o.indexOf('C:\\>type memo.txt'), o.indexOf('C:\\>type memo.txt') + 80));
    check(`MyDOS（${type}）：AS（C で書いたアセンブラ）でアセンブルして実行`,
      o.includes(nl('C:\\>as -o hi2.exe hi.s\nhi2.exe: 218 bytes\n')) && o.includes(nl('C:\\>hi2 MyCPU\nHello, MyCPU!\n')),
      o.slice(o.indexOf('C:\\>as -o'), o.indexOf('C:\\>as -o') + 120));
    check(`MyDOS（${type}）：0 で割るプログラムは止めて C:\\> に戻る`,
      o.includes(nl('Dividing by zero...\n\nProgram terminated: divide by zero at ')) && !o.includes('never printed'), '');
    check(`MyDOS（${type}）：エラーの出し方`, o.includes(nl('C:\\>type nofile.txt\nFile not found\n')) &&
      o.includes(nl('C:\\>type\nRequired parameter missing\n')) && o.includes(nl('C:\\>del nofile\nFile not found\n')) &&
      o.includes(nl('C:\\>ren renamed.txt hello.exe\nDuplicate file name or file not found\n')), '');
    check(`MyDOS（${type}）：COPY CON・COPY・リダイレクト・TOUPPER`, o.includes(nl('^Z\n        1 file(s) copied\n')) &&
      o.includes(nl(`${readme.length} bytes converted\n`)) && /RENAMED  TXT +32 01-01-26  12:00a/.test(o) && o.includes(nl('fib(3) = 2\n\nC:\\>')), '');
    check(`MyDOS（${type}）：.BAT から .BAT、シャットダウン`, o.includes(nl('C:\\>FIB 10\nfib(0) = 0\n')) &&
      o.includes("safe to turn off") && r.cpu.halted.kind === 'hlt', o.slice(-300));
    if (mtoolsOk) {
      // 書いた後のイメージを fsck.fat と mtools で確かめる
      const part = path.join(TMP, `${type}.part.img`);
      fs.writeFileSync(part, disk.toBuffer().subarray(disk.info.partStart * 512));
      const fsck = spawnSync('fsck.fat', ['-n', part], { encoding: 'utf8' });
      check(`MyDOS（${type}）：書いた後のカードを fsck.fat で確かめてエラーなし`, fsck.status === 0, fsck.stdout + fsck.stderr);
      const mt = (n) => spawnSync('mtype', ['-i', part, '::' + n], { env, encoding: 'latin1' }).stdout;
      check(`MyDOS（${type}）：書いたファイルを mtools で読める`, mt('RENAMED.TXT') === 'Hello from MyDOS!\r\nSecond line\r\n' &&
        mt('UP.TXT') === readme.toUpperCase() && /fib\(3\) = 2\r\n$/.test(mt('LIST.TXT')) && mt('NOTE.TXT') === '',
        JSON.stringify(mt('RENAMED.TXT')) + ' ' + JSON.stringify(mt('LIST.TXT').slice(-40)));
    }
  }

  // 本物の道具（mkfs.fat・mtools）で作ったカード：長い名前のファイルを消す・名前を変えても壊れないか
  if (mtoolsOk) {
    for (const F of ['16', '32']) {
      const img = path.join(TMP, `real${F}.img`);
      fs.writeFileSync(img, Buffer.alloc(40 * 1024 * 1024));
      execFileSync('mkfs.fat', ['-F', F, '-n', 'REALDISK', img]);
      const put = (name, data) => { const f = path.join(TMP, name); fs.writeFileSync(f, data); execFileSync('mcopy', ['-i', img, f, '::'], { env }); };
      put('A long file name.txt', 'This file has a long name.\r\n');
      put('Another long name.txt', 'another\r\n');
      for (const f of files) if (/^(MYDOS\.SYS|HELLO\.EXE)$/.test(f.name)) put(f.name, f.data);
      execFileSync('mmd', ['-i', img, '::GAMES'], { env });
      const mfree = /([\d ]+) bytes free/.exec(execFileSync('mdir', ['-i', img, '::'], { env, encoding: 'utf8' }))[1].replace(/ /g, '');
      const disk = fat.bufferDisk(new Uint8Array(fs.readFileSync(img)));
      r = runSim(bios, { input: ' dir\rtype alongf~1.txt\rhello real\rdel alongf~1.txt\rren anothe~1.txt short.txt\rshutdown\r', disk, max: 60_000_000 });
      const o = r.out;
      check(`mkfs.fat -F ${F} のカード（パーティション表なし・長い名前・サブディレクトリ）から起動`,
        o.includes('Volume in drive C is REALDISK') && /ALONGF~1 TXT +28 /.test(o) && /GAMES +<DIR>/.test(o) &&
        o.includes(nl('This file has a long name.\n')) && o.includes(nl('Hello, real!\n')) && o.includes(` ${mfree} bytes free`),
        o.slice(o.indexOf('C:\\>dir'), o.indexOf('C:\\>dir') + 900) + '\nmdir: ' + mfree);
      fs.writeFileSync(img, disk.buffer);
      const fsck = spawnSync('fsck.fat', ['-n', img], { encoding: 'utf8' });
      const md = execFileSync('mdir', ['-i', img, '::'], { env, encoding: 'utf8' });
      check(`mkfs.fat -F ${F}：長い名前のファイルを DEL・REN しても fsck.fat でエラーなし`,
        fsck.status === 0 && !/ALONGF~1/.test(md) && /SHORT +TXT/.test(md) && !/Another long name/.test(md), fsck.stdout + md);
    }
  } else console.log('  --   fsck.fat・mtools がないので、本物の道具での確認は飛ばす');

  // UART から起動：U → 'MC' + 長さ + プログラム → 動いて、キーで再起動 → SD から MyDOS → シャットダウン
  const app = assemble(fs.readFileSync(path.join(ROOT, 'examples/uartboot/hello_uart.asm'), 'utf8')).image.subarray(0x20000);
  const frame = Buffer.concat([Buffer.from('MC', 'latin1'), Buffer.from(new Uint32Array([app.length]).buffer), Buffer.from(app)]);
  const bootInput = Buffer.concat([Buffer.from('u', 'latin1'), frame, Buffer.from('x shutdown\r', 'latin1')]).toString('latin1');
  r = runSim(bios, { input: bootInput, disk: makeDisk(diskSources), max: 40_000_000 });
  check('BIOS：UART から起動したプログラムが動き、再起動して SD の MyDOS へ',
    r.out.includes('Loaded ' + app.length + ' bytes') && r.out.includes('1 4 9 16 25 36 49 64 81 100') &&
    r.out.split('MyCPU BIOS').length === 3 && r.out.includes("safe to turn off"), r.out.slice(-400));

  // Verilog 用の小さい FAT16（1 クラスタ 1 セクタ、パーティションは 32 から）
  // Verilog 用の小さいカード（約 2MB）には、C コンパイラ一式（CC.EXE・LIBC.S など）は入れない
  const compilerNames = new Set(require('../tools/cc.js').compilerFiles().map((f) => f.name));
  const small = () => makeDisk(diskSources.filter((f) => !compilerNames.has(f.name)), { type: 'fat16', spc: 1, partStart: 32, totalSectors: 4300 });
  cases.push(
    { name: 'mydos-sd', file: 'bios.asm', disk: small(), max: 60_000_000,
      input: ' hello rtl\rcopy con a.txt\rwritten by rtl\r\x1a\rtype a.txt\rren a.txt b.txt\rtype b.txt\rdel b.txt\rcrash\rbig\rprimes\rshutdown\r' },
    { name: 'mydos-uart', file: 'bios.asm', input: bootInput, disk: small(), max: 60_000_000 },
    { name: 'hello', file: 'hello.asm' },
    { name: 'sdram', file: 'sdram.asm', sdram: true, trace: true },
    { name: 'pipeline', file: 'pipeline.asm', trace: true },
    { name: 'selftest32', file: 'selftest32.asm' },
    { name: 'trap', file: 'trap.asm', regs: false },
    { name: 'fib', file: 'fib.asm', max: 60_000_000 },
    { name: 'console', file: 'console.asm', input },
    { name: 'colors', file: 'colors.asm', ppm: true },
    { name: 'gfx', file: 'gfx.asm', ppm: true },   // グラフィック画面（SDRAM のフレームバッファ・パレット）
  );
}

// ---- C コンパイラ ----
console.log('C コンパイラ（cc/。chibicc のテストをこの CPU で動かす）');
{
  // x86 のアセンブリ・pthread を使うものは除く（この CPU にはない）
  const NA = ['asm', 'atomic', 'tls'];
  const results = require('./cctest.js').run();
  const expect = results.filter((r) => !NA.includes(r.name));
  const bad = expect.filter((r) => !r.ok);
  check(`chibicc のテスト ${expect.length} 本が通る（x86・pthread の ${NA.length} 本は除く）`,
    bad.length === 0 && expect.length >= 38, bad.map((r) => `${r.name}：${r.why}`).join('\n'));
}

// ---- 浮動小数点（libc/softfloat.c・fltio.c・math.c） ----
if (spawnSync('gcc', ['--version']).error) {
  console.log('  --   gcc がないので、浮動小数点のライブラリの比較は飛ばす');
} else {
  const exe = (name) => path.join(TMP, name);
  const gcc = (out, args) => execFileSync('gcc', ['-O2', '-o', exe(out), ...args.map((f) => (f.startsWith('-') ? f : path.join(ROOT, f)))], { stdio: ['ignore', 'ignore', 'pipe'] });
  const runExe = (name, args) => spawnSync(exe(name), args, { encoding: 'utf8' });

  gcc('floattest', ['test/floattest.c', 'libc/softfloat.c']);
  let r = runExe('floattest', ['300000']);
  check('ソフトウェアの浮動小数点（libc/softfloat.c）：四則・比較・変換が PC の FPU とビット単位で同じ（30 万組）',
    r.status === 0, r.stdout.trim());
  // アセンブリ版（libc/softfloat.s）は、この CPU で C 版と比べる
  const fa = require('./cctest.js').runC([path.join(ROOT, 'test/fasmtest.c')], { max: 5_000_000_000 });
  check('浮動小数点のアセンブリ版（libc/softfloat.s）：この CPU で C 版とビット単位で同じ（double・float 2 万組ずつ）',
    fa.ok, fa.why + '\n' + fa.out.slice(0, 1000));

  gcc('fltiotest', ['-Dstrtod=my_strtod', '-Dstrtof=my_strtof', '-Dstrtold=my_strtold', '-Datof=my_atof', 'test/fltiotest.c', 'libc/fltio.c']);
  r = runExe('fltiotest', ['20000']);
  check('printf の %f・%e・%g と strtod（libc/fltio.c）：glibc と同じ文字列・同じビット列（2 万回）', r.status === 0, r.stdout.trim());

  gcc('mathtest', ['-fno-builtin', '-fno-math-errno', 'test/mathtest.c', 'libc/math.c', '-lm']);
  r = runExe('mathtest', ['200000']);
  check('数学の関数（libc/math.c）：sqrt・fmod などは正確、sin・exp・pow などは 2 ulp 以内（glibc の long double と比べる）',
    r.status === 0, r.stdout.trim());

  gcc('scanftest', ['test/scanftest.c']);
  r = runExe('scanftest', ['100000']);
  check('scanf の仲間（libc/scanf.c）：glibc の sscanf と同じ戻り値・同じ値（10 万通り）', r.status === 0, r.stdout.trim());

  // 同じプログラムを、この CPU（シミュレータ）と PC で動かして、出力が同じ
  execFileSync('gcc', ['-O0', '-ffp-contract=off', '-fno-builtin', '-o', exe('cfloat'), path.join(ROOT, 'test/cfloat.c'), path.join(ROOT, 'libc/math.c'), '-lm']);
  const want = runExe('cfloat', []).stdout;
  const got = require('./cctest.js').runC([path.join(ROOT, 'test/cfloat.c')], { max: 400_000_000 });
  const diff = got.out.split('\n').findIndex((l, i) => l !== want.split('\n')[i]);
  check('C の float・double（test/cfloat.c）：この CPU で動かした出力が、PC の gcc で動かしたものと同じ',
    got.ok && got.out === want, got.why || `${diff + 1} 行目：${got.out.split('\n')[diff]}（PC：${want.split('\n')[diff]}）`);
}

// ---- C のアセンブラ ----
{
  const results = require('./astest.js').run();
  if (!results) console.log('  --   gcc がないので、C のアセンブラ（disk/as.c）の比較は飛ばす');
  else {
    const bad = results.filter((r) => !r.ok);
    check(`C のアセンブラ（disk/as.c を gcc で）：JS と同じバイト列 ${results.length - 3} 本、別々のファイルのリンクも tools/cc.js と同じ、-lib LIBC でつないだものが動く`,
      bad.length === 0, bad.map((r) => `${r.name}：${r.why}`).join('\n'));
  }
}

// ---- 4 ----
console.log('Verilog（iverilog）');
if (spawnSync('iverilog', ['-V']).error) {
  console.log('  --   iverilog がないので飛ばす');
} else {
  const rtl = ['rtl/cpu.v', 'rtl/soc.v', 'rtl/sdram.v', 'rtl/uart.v', 'rtl/video.v'].map((f) => path.join(ROOT, f));
  const p = (f) => path.join(ROOT, f);

  execFileSync('iverilog', ['-g2012', '-o', path.join(TMP, 'tmds.vvp'), p('tb/tb_tmds.v'), p('rtl/tmds.v')]);
  const tm = execFileSync('vvp', ['-n', path.join(TMP, 'tmds.vvp')], { encoding: 'utf8' });
  check('TMDS 符号器：元に戻せて、直流の偏りが小さい', /tb_tmds: 0 件 NG/.test(tm), tm.trim());

  execFileSync('iverilog', ['-g2012', '-o', path.join(TMP, 'sdram.vvp'), p('tb/tb_sdram.v'), p('tb/sdram_model.v'), p('rtl/sdram.v')]);
  const sdr = execFileSync('vvp', ['-n', path.join(TMP, 'sdram.vvp')], { encoding: 'utf8' });
  check('SDRAM の制御回路：ランダムな読み書きが合い、モデルがタイミング違反を見つけない', /tb_sdram: 0 件 NG/.test(sdr), sdr.trim());

  const top = spawnSync('iverilog', ['-g2012', '-I', p('rtl'), '-o', path.join(TMP, 'top.vvp'), '-s', 'top_tangnano20k',
    p('rtl/gowin/top_tangnano20k.v'), ...rtl, p('rtl/tmds.v'), p('tb/gowin_stubs.v')], { encoding: 'utf8' });
  check('Tang Nano 20K のトップがコンパイルできる（Gowin 部品は代わりのモジュール）', top.status === 0, top.stderr);

  for (const c of cases) {
    const base = path.join(TMP, c.name);
    const source = src(c.file);
    const { image, symbols } = assemble(source);
    fs.writeFileSync(base + '_even.hex', toReadmemh(image, isa.MAP.ROM_SIZE / 4, 0));
    fs.writeFileSync(base + '_odd.hex', toReadmemh(image, isa.MAP.ROM_SIZE / 4, 1));

    // シミュレータ側の答え
    const sim = runSim(source, { input: c.input, disk: c.disk, max: 60_000_000, trace: c.trace });
    const sdArgs = [];
    if (c.disk) {
      // 中身のあるセクタだけ書く（@番地 で飛ばす）
      const lines = [];
      [...c.disk.map].sort((x, y) => x[0] - y[0]).forEach(([lba, sec]) => {
        lines.push('@' + (lba * 512).toString(16));
        for (const b of sec) lines.push(b.toString(16).padStart(2, '0'));
      });
      fs.writeFileSync(base + '.sd.hex', lines.join('\n') + '\n');
      sdArgs.push(`-Ptb.SD_HEX="${base}.sd.hex"`, `-Ptb.SD_SECTORS=${c.disk.sectors}`);
    }
    // Verilog 側
    execFileSync('iverilog', ['-g2012', '-DMYCPU_SIM', '-I', path.join(ROOT, 'rtl'), '-o', base + '.vvp',
      `-Ptb.ROM_EVEN_HEX="${base}_even.hex"`, `-Ptb.ROM_ODD_HEX="${base}_odd.hex"`, `-Ptb.FONT_HEX="${path.join(ROOT, 'font/font8x16.hex')}"`, ...sdArgs,
      path.join(ROOT, 'tb/tb_soc.v'), path.join(ROOT, 'tb/sd_model.v'), path.join(ROOT, 'tb/sdram_model.v'), ...rtl]);
    const args = ['-n', base + '.vvp', `+uart=${base}.uart`, `+regs=${base}.regs`, `+max=${c.max || 20_000_000}`];
    if (c.input) { fs.writeFileSync(base + '.rx', Buffer.from(c.input, 'latin1')); args.push(`+rx=${base}.rx`); }
    if (c.ppm) args.push(`+ppm=${base}.ppm`);
    if (c.trace) args.push(`+trace=${base}.trace`);
    const log = execFileSync('vvp', args, { encoding: 'utf8' });
    const halted = /停止 halt_code=1/.test(log);
    const out = fs.readFileSync(base + '.uart', 'latin1');
    check(`${c.name}：HLT で止まる`, halted, log.trim());
    if (c.sdram) {
      const m = /SDRAM 読み出し (\d+) 回・書き込み (\d+) 回、タイミング違反 (\d+) 件/.exec(log);
      check(`${c.name}：SDRAM を使い、タイミング違反がない`, m && +m[1] > 0 && +m[2] > 0 && m[3] === '0', log.trim());
    }
    check(`${c.name}：UART 出力が一致`, out === sim.out, JSON.stringify(out.slice(0, 200)) + '\n≠ ' + JSON.stringify(sim.out.slice(0, 200)));
    if (c.trace) {
      // 実行した命令の順番。UART に出す部分（io_begin〜io_end）は、送信を待つ回数が違うので除く
      const lo = Number(symbols.get('io_begin')), hi = Number(symbols.get('io_end'));
      const keep = (pc) => !(pc >= lo && pc < hi);
      const want = sim.trace.filter(keep);
      const got = fs.readFileSync(base + '.trace', 'utf8').trim().split('\n').map((x) => parseInt(x, 16)).filter(keep);
      let at = 0;
      while (at < want.length && want[at] === got[at]) at++;
      check(`${c.name}：実行した命令の順番がシミュレータと同じ（${want.length} 命令）`, at === want.length && got.length === want.length,
        `${at} 番目で違う：${(got[at] || 0).toString(16)}（シミュレータは ${(want[at] || 0).toString(16)}）`);
    }
    if (c.regs !== false) {
      const regs = fs.readFileSync(base + '.regs', 'utf8');
      check(`${c.name}：レジスタが一致`, regs === sim.cpu.dumpRegs(), regs + '≠\n' + sim.cpu.dumpRegs());
    }
    if (c.ppm) {
      const want = Buffer.concat([Buffer.from(`P6\n${video.WIDTH} ${video.HEIGHT}\n255\n`), Buffer.from(video.renderCpu(sim.cpu))]);
      const got = fs.readFileSync(base + '.ppm');
      let diff = -1;
      for (let i = 0; i < want.length; i++) if (want[i] !== got[i]) { diff = i; break; }
      check(`${c.name}：表示回路の 1 フレームがシミュレータの絵と一致`, got.length === want.length && diff < 0,
        `長さ ${got.length} / ${want.length}、最初の違い ${diff}`);
    }
  }
}

if (!spawnSync('iverilog', ['-V']).error) {
  // 速さ：命令ごとのクロック数が上限を超えていないか（test/cpi.asm。Verilog だけ）
  const base = path.join(TMP, 'cpi');
  const { image } = assemble(fs.readFileSync(path.join(ROOT, 'test/cpi.asm'), 'utf8'));
  fs.writeFileSync(base + '_even.hex', toReadmemh(image, isa.MAP.ROM_SIZE / 4, 0));
  fs.writeFileSync(base + '_odd.hex', toReadmemh(image, isa.MAP.ROM_SIZE / 4, 1));
  const rtl = ['rtl/cpu.v', 'rtl/soc.v', 'rtl/sdram.v', 'rtl/uart.v', 'rtl/video.v', 'tb/tb_soc.v', 'tb/sd_model.v', 'tb/sdram_model.v']
    .map((f) => path.join(ROOT, f));
  execFileSync('iverilog', ['-g2012', '-DMYCPU_SIM', '-I', path.join(ROOT, 'rtl'), '-o', base + '.vvp',
    `-Ptb.ROM_EVEN_HEX="${base}_even.hex"`, `-Ptb.ROM_ODD_HEX="${base}_odd.hex"`,
    `-Ptb.FONT_HEX="${path.join(ROOT, 'font/font8x16.hex')}"`, ...rtl]);
  execFileSync('vvp', ['-n', base + '.vvp', `+uart=${base}.uart`], { encoding: 'utf8' });
  const rows = fs.readFileSync(base + '.uart', 'latin1').trim().split(/\r?\n/).map((l) => /^(.*): (\d+) \[([\d.]+)\]$/.exec(l));
  const loop = +rows[0][2];
  const slow = [], table = [];
  for (const m of rows.slice(1)) {
    const cpi = (+m[2] - loop) / 160;
    table.push(`${m[1]} ${cpi.toFixed(2)}`);
    if (cpi > +m[3] + 0.01) slow.push(`${m[1]}：${cpi.toFixed(2)} クロック（上限 ${m[3]}）`);
  }
  check('速さ：1 命令あたりのクロック数が上限以内（ふつうの命令 1、読み出しの直後に使う 2、M 形式 3 …）', rows.length > 5 && slow.length === 0,
    slow.join('\n'));
  console.log('       ' + table.join(' / '));
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${passed} 件 ok、${failed} 件 NG`);
process.exit(failed ? 1 : 0);
