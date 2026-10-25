#!/usr/bin/env node
// アセンブラ（コマンドライン）
//   node asm/asm.js prog.asm [-o 出力名]
// 出力: 出力名.bin（番地 0 からの生バイナリ）、.lst（確認用リスト）、.hex（ROM 用 $readmemh）
'use strict';
const fs = require('fs');
const path = require('path');
const { assemble, toReadmemh, AsmError } = require('../lib/assembler.js');
const { MAP } = require('../lib/isa.js');

function main(argv) {
  const args = argv.slice(2);
  let input = null, out = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '-o') out = args[++i];
    else if (!input) input = args[i];
    else return usage();
  }
  if (!input) return usage();
  if (!out) out = input.replace(/\.asm$/i, '');

  let result;
  try {
    result = assemble(fs.readFileSync(input, 'utf8'));
  } catch (e) {
    if (!(e instanceof AsmError)) throw e;
    for (const err of e.errors) console.error(`${input}:${err.line}: ${err.message}`);
    process.exit(1);
  }
  fs.writeFileSync(out + '.bin', result.image);
  fs.writeFileSync(out + '.lst', result.listing);
  fs.writeFileSync(out + '.hex', toReadmemh(result.image, MAP.ROM_SIZE / 4));
  if (result.image.length > MAP.ROM_SIZE) {
    console.error(`注意: ROM（${MAP.ROM_SIZE} バイト）の外まで書いている。.hex には ROM の分だけ入る`);
  }
  console.log(`${path.basename(input)}: ${result.image.length} バイト → ${out}.bin / .lst / .hex`);
}

function usage() {
  console.error('使い方: node asm/asm.js prog.asm [-o 出力名]');
  process.exit(2);
}

main(process.argv);
