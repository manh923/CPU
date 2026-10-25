#!/usr/bin/env node
// UART 起動（examples/bios.asm の BIOS で U キー）で送るファイルを作る
//   node tools/mkboot.js prog.asm|prog.bin [-o 出力] [--base 0x20000]
// 中身：'M' 'C'、長さ（4 バイト、リトルエンディアン）、番地 base からのプログラム。
// プログラムは .org 0x20000 で書いておく。できたファイルは端末ソフトのバイナリ送信で送るか、
// シミュレータなら sim.js --rx-file で渡す。
'use strict';
const fs = require('fs');
const { assemble, AsmError } = require('../lib/assembler.js');

const OS_MAX = 0xB000;

function main(argv) {
  let input = null, out = null, base = 0x20000;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '-o') out = argv[++i];
    else if (argv[i] === '--base') base = Number(argv[++i]);
    else if (!input) input = argv[i];
    else usage();
  }
  if (!input || !Number.isInteger(base)) usage();
  if (!out) out = input.replace(/\.(asm|bin)$/i, '') + '.boot';

  let image;
  if (/\.asm$/i.test(input)) {
    try {
      image = assemble(fs.readFileSync(input, 'utf8')).image;
    } catch (e) {
      if (!(e instanceof AsmError)) throw e;
      for (const err of e.errors) console.error(`${input}:${err.line}: ${err.message}`);
      process.exit(1);
    }
  } else image = new Uint8Array(fs.readFileSync(input));

  if (image.length <= base) {
    console.error(`番地 0x${base.toString(16)} から先が空。.org 0x${base.toString(16)} で書いたか確かめる`);
    process.exit(1);
  }
  const body = image.subarray(base);
  if (body.length > OS_MAX) {
    console.error(`大きすぎる（${body.length} バイト。最大 ${OS_MAX}）`);
    process.exit(1);
  }
  const head = Buffer.alloc(6);
  head.write('MC', 0, 'latin1');
  head.writeUInt32LE(body.length, 2);
  fs.writeFileSync(out, Buffer.concat([head, Buffer.from(body)]));
  console.log(`${out}: ${body.length} バイト（0x${base.toString(16)} から）`);
}

function usage() {
  console.error('使い方: node tools/mkboot.js prog.asm|prog.bin [-o 出力] [--base 0x20000]');
  process.exit(2);
}

main(process.argv);
