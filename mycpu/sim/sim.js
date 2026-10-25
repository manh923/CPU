#!/usr/bin/env node
// シミュレータ（コマンドライン）
//   node sim/sim.js prog.asm|prog.bin [オプション]
//     --cpu 32|64     CPU の bit 数（既定 32）
//     --trace         1 命令ずつ表示（標準エラー）
//     --max N         N 命令で打ち切る（既定 1 億）
//     --input 文字列  UART 受信に最初から入れておく（\n などのエスケープ可）
//     --rx-file 名前  ファイルの中身を UART 受信に入れておく（--input の後ろに続く）
//     --screen        テキスト VRAM を端末にそのまま表示し続ける
//     --png 名前      止まったときの画面を PNG で保存
//     --ppm 名前      同じく PPM（Verilog のテストベンチの出力と比べる用）
//     --regs 名前     止まったときのレジスタ一覧をファイルへ（- なら標準エラー）
//     --realtime      タイマーを実時間で進める（既定は 1 命令 = 1µs で毎回同じ結果）
// 標準入力は UART 受信につながる。端末ならキーを押した瞬間に届く。Ctrl-] で終了。
'use strict';
const fs = require('fs');
const zlib = require('zlib');
const CPU = require('../lib/cpu.js');
const video = require('../lib/video.js');
const { assemble, AsmError } = require('../lib/assembler.js');

function parseArgs(argv) {
  const o = { cpu: 32, max: 100_000_000, trace: false, screen: false, realtime: false, input: '' };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const val = () => argv[++i];
    switch (a) {
      case '--cpu': o.cpu = +val(); break;
      case '--trace': o.trace = true; break;
      case '--max': o.max = +val(); break;
      case '--input': o.input = unescape(val()); break;
      case '--rx-file': o.rxFile = val(); break;
      case '--screen': o.screen = true; break;
      case '--png': o.png = val(); break;
      case '--ppm': o.ppm = val(); break;
      case '--regs': o.regs = val(); break;
      case '--realtime': o.realtime = true; break;
      default:
        if (a.startsWith('--') || o.file) usage();
        o.file = a;
    }
  }
  if (!o.file || (o.cpu !== 32 && o.cpu !== 64)) usage();
  return o;
}

// \n \r \t \b \0 \\ \xHH を解釈する
function unescape(s) {
  const E = { n: '\n', r: '\r', t: '\t', b: '\b', '0': '\0', '\\': '\\' };
  return s.replace(/\\(x[0-9a-fA-F]{2}|.)/g, (_, e) => (e[0] === 'x' ? String.fromCharCode(parseInt(e.slice(1), 16)) : E[e] ?? e));
}

function usage() {
  console.error('使い方: node sim/sim.js prog.asm|prog.bin [--cpu 64] [--trace] [--screen] [--png out.png] ...');
  process.exit(2);
}

function loadImage(file) {
  if (!/\.asm$/i.test(file)) return new Uint8Array(fs.readFileSync(file));
  try {
    return assemble(fs.readFileSync(file, 'utf8')).image;
  } catch (e) {
    if (!(e instanceof AsmError)) throw e;
    for (const err of e.errors) console.error(`${file}:${err.line}: ${err.message}`);
    process.exit(1);
  }
}

// ---- 画像 ----

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function png(rgb, w, h) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    Buffer.from(rgb.buffer, rgb.byteOffset + y * w * 3, w * 3).copy(raw, y * (w * 3 + 1) + 1);
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2; // 8bit RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

function ppm(rgb, w, h) {
  return Buffer.concat([Buffer.from(`P6\n${w} ${h}\n255\n`), Buffer.from(rgb)]);
}

// ---- 端末への画面表示（ANSI） ----

const ANSI = [0, 4, 2, 6, 1, 5, 3, 7]; // CGA の色番号 → ANSI の色番号
function drawScreen(vram) {
  const { COLS, ROWS } = require('../lib/isa.js').TEXT;
  let out = '\x1b[H';
  for (let r = 0; r < ROWS; r++) {
    let last = -1;
    for (let c = 0; c < COLS; c++) {
      const i = (r * COLS + c) * 2, ch = vram[i], attr = vram[i + 1];
      if (attr !== last) {
        const fg = attr & 15, bg = attr >> 4;
        out += `\x1b[${(fg & 8 ? 90 : 30) + ANSI[fg & 7]};${(bg & 8 ? 100 : 40) + ANSI[bg & 7]}m`;
        last = attr;
      }
      out += ch >= 0x20 && ch < 0x7f ? String.fromCharCode(ch) : ' ';
    }
    out += '\x1b[0m\r\n';
  }
  process.stdout.write(out);
}

function main() {
  const o = parseArgs(process.argv);
  const t0 = process.hrtime.bigint();
  const cpu = new CPU({
    xlen: o.cpu,
    onTx: (b) => { if (!o.screen) process.stdout.write(Buffer.from([b])); },
    clock: o.realtime ? () => Number((process.hrtime.bigint() - t0) / 1000n) : null,
    trace: o.trace ? (pc, text) => process.stderr.write(pc.toString(16).padStart(8, '0') + '  ' + text + '\n') : null,
  });
  cpu.load(loadImage(o.file));
  cpu.pushRx(Buffer.from(o.input, 'latin1'));
  if (o.rxFile) cpu.pushRx(fs.readFileSync(o.rxFile));

  const interactive = process.stdin.isTTY;
  let stdinOpen = false;
  if (interactive) {
    process.stdin.setRawMode(true);
    stdinOpen = true;
    process.stdin.on('data', (d) => {
      if (d.includes(0x1d)) finish('Ctrl-] で終了');
      cpu.pushRx(d);
    });
  } else if (!o.input && !o.rxFile) {
    // パイプからの入力は、全部読んでから UART に入れる
    try { cpu.pushRx(fs.readFileSync(0)); } catch (_) { /* 入力なし */ }
  }
  if (o.screen) process.stdout.write('\x1b[2J\x1b[?25l');

  let done = false;
  function finish(why) {
    if (done) return;
    done = true;
    if (interactive) process.stdin.setRawMode(false);
    if (stdinOpen) process.stdin.pause();
    if (o.screen) { drawScreen(cpu.vram); process.stdout.write('\x1b[?25h'); }
    const h = cpu.halted;
    const msg = h ? (h.kind === 'hlt' ? `HLT（${cpu.steps} 命令）` : `停止: ${h.message}`) : why;
    process.stderr.write(`\n[${msg}]\n`);
    if (o.regs) {
      if (o.regs === '-') process.stderr.write(cpu.dumpRegs());
      else fs.writeFileSync(o.regs, cpu.dumpRegs());
    }
    if (o.png || o.ppm) {
      const rgb = video.render(cpu.vram);
      if (o.png) fs.writeFileSync(o.png, png(rgb, video.WIDTH, video.HEIGHT));
      if (o.ppm) fs.writeFileSync(o.ppm, ppm(rgb, video.WIDTH, video.HEIGHT));
    }
    process.exitCode = h && h.kind !== 'hlt' ? 1 : 0;
  }

  // 少しずつ実行して、合間にキー入力と画面更新を受け付ける
  let lastDraw = 0;
  function tick() {
    if (done) return;
    const n = cpu.run(Math.min(200_000, o.max - cpu.steps));
    if (o.screen && cpu.vramChanged && Date.now() - lastDraw > 30) {
      cpu.vramChanged = false;
      lastDraw = Date.now();
      drawScreen(cpu.vram);
    }
    if (cpu.halted) return finish();
    if (cpu.steps >= o.max) return finish(`${o.max} 命令で打ち切り`);
    // WFI で入力待ちのまま、入力の来ようがないなら終わる
    if (cpu.wfi && !interactive && !o.realtime && !cpu.timerEn) return finish('WFI のまま入力がない');
    if (n === 0 || cpu.wfi) setTimeout(tick, 1);
    else setImmediate(tick);
  }
  tick();
}

main();
