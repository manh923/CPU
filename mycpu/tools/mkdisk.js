#!/usr/bin/env node
// SD カードの中身を作る（MyDOS の C: ドライブ）
//   node tools/mkdisk.js [フォルダ（既定 disk/）] --files 出力フォルダ
//       ファイルを作るだけ。FAT でフォーマットした SD カードに PC からそのまま写す
//   node tools/mkdisk.js [フォルダ] -o disk.img [--fat32] [--size MB]
//       ディスクイメージを作る（シミュレータの --sd 用。dd などで SD カードに書いてもよい）
// NAME.exe.asm → NAME.EXE、NAME.com.asm → NAME.COM（.org 0x26000）、NAME.sys.asm → NAME.SYS（.org 0x20000）に
// アセンブルする。ほかのファイルはそのまま。
'use strict';
const fs = require('fs');
const path = require('path');
const { makeFile, makeDisk } = require('../lib/disk.js');
const { AsmError } = require('../lib/assembler.js');

// NAME.c はコンパイルして NAME.EXE も作る（tools/cc.js）
const readSources = (dir) => require('./cc.js').diskSources(dir);

function main(argv) {
  let dir = path.join(__dirname, '..', 'disk'), out = null, filesDir = null, type = 'fat16', sizeMB = null;
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-o') out = argv[++i];
    else if (a === '--files') filesDir = argv[++i];
    else if (a === '--fat32') type = 'fat32';
    else if (a === '--size') sizeMB = Number(argv[++i]);
    else if (!a.startsWith('-')) dir = a;
    else usage();
  }
  if (!out && !filesDir) usage();
  const sources = readSources(dir);
  try {
    if (filesDir) {
      fs.mkdirSync(filesDir, { recursive: true });
      for (const s of sources) {
        const f = makeFile(s.name, s.contents);
        fs.mkdirSync(path.dirname(path.join(filesDir, f.name)), { recursive: true });   // INCLUDE/ など
        fs.writeFileSync(path.join(filesDir, f.name), f.data);
        console.log(`${f.name.padEnd(12)} ${String(f.data.length).padStart(7)} バイト`);
      }
    }
    if (out) {
      const disk = makeDisk(sources, { type, sizeMB: sizeMB || undefined });
      fs.writeFileSync(out, disk.toBuffer());
      console.log(`${out}: ${disk.info.type.toUpperCase()}、${(disk.sectors * 512 / 1048576).toFixed(1)}MB、ファイル ${sources.length} 個`);
    }
  } catch (e) {
    if (!(e instanceof AsmError)) throw e;
    for (const err of e.errors) console.error(`${err.line}: ${err.message}`);
    process.exit(1);
  }
}

function usage() {
  console.error('使い方: node tools/mkdisk.js [フォルダ] --files 出力フォルダ\n        node tools/mkdisk.js [フォルダ] -o disk.img [--fat32] [--size MB]');
  process.exit(2);
}

main(process.argv);
