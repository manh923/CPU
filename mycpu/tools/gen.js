// opcodes.csv と examples/*.asm から、手で書かないファイルを作る。
//   lib/opcodes.js   … アセンブラ・シミュレータ用の命令表
//   lib/examples.js  … ブラウザ版に載せるサンプル
//   rtl/opcodes.vh   … Verilog デコーダ用の定数
// 使い方: node tools/gen.js        （作り直す）
//         node tools/gen.js --check（作り直さず、古くなっていないか確認だけ）
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

function parseCsv(text) {
  const rows = [];
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') continue;
    const cells = [];
    let cur = '', quoted = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (quoted) {
        if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; }
        else if (c === '"') quoted = false;
        else cur += c;
      } else if (c === '"') quoted = true;
      else if (c === ',') { cells.push(cur); cur = ''; }
      else cur += c;
    }
    cells.push(cur);
    rows.push(cells);
  }
  const head = rows.shift();
  return rows.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])));
}

function loadOpcodes() {
  const rows = parseCsv(fs.readFileSync(path.join(ROOT, 'opcodes.csv'), 'utf8'));
  const seen = new Map();
  return rows.map((r) => {
    const width = parseInt(r.width, 2);
    const group = parseInt(r.group, 16);
    const op = parseInt(r.op, 16);
    const opcode = width | (group << 2) | (op << 6);
    if (opcode !== parseInt(r.opcode14, 16)) {
      throw new Error(`${r.mnemonic}: opcode14 が width/group/op と合わない`);
    }
    if (seen.has(opcode)) throw new Error(`${r.mnemonic}: ${seen.get(opcode)} とオペコードが重複`);
    seen.set(opcode, r.mnemonic);
    const operands = r.operands.split(',').map((s) => s.trim()).filter(Boolean);
    return { mnemonic: r.mnemonic, width, group, op, opcode, form: r.form, operands, description: r.description };
  });
}

function genOpcodesJs(ops) {
  const body = ops.map((o) => '    ' + JSON.stringify(o)).join(',\n');
  return `// 自動生成（tools/gen.js が opcodes.csv から作る）。手で編集しない。
(function (root) {
  var OPCODES = [
${body}
  ];
  if (typeof module === 'object' && module.exports) module.exports = OPCODES;
  else (root.MyCPU = root.MyCPU || {}).OPCODES = OPCODES;
})(typeof self !== 'undefined' ? self : this);
`;
}

function genVh(ops) {
  const lines = ops.map((o) => {
    const name = ('OP_' + o.mnemonic).padEnd(18);
    return `localparam [13:0] ${name} = 14'h${o.opcode.toString(16).toUpperCase().padStart(4, '0')}; // ${o.description}`;
  });
  const validFn = (name, widths, comment) => {
    const names = ops.filter((o) => widths.includes(o.width)).map((o) => 'OP_' + o.mnemonic);
    const cases = [];
    for (let i = 0; i < names.length; i += 6) cases.push('      ' + names.slice(i, i + 6).join(', '));
    return `// ${comment}
function automatic ${name}(input [13:0] o);
  begin
    case (o)
${cases.join(',\n')}:
        ${name} = 1'b1;
      default: ${name} = 1'b0;
    endcase
  end
endfunction`;
  };
  return `// 自動生成（tools/gen.js が opcodes.csv から作る）。手で編集しない。
// 14bit オペコード = {op[7:0], group[3:0], width[1:0]}
${lines.join('\n')}

${validFn('op_valid32', [0, 1], '32bit CPU で使える命令（width 00 / 01）')}

${validFn('op_valid64', [0, 1, 2], '64bit CPU で使える命令（width 00 / 01 / 10）')}
`;
}

function genExamplesJs() {
  const dir = path.join(ROOT, 'examples');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.asm')).sort();
  const items = files.map((f) => ({ name: f, source: fs.readFileSync(path.join(dir, f), 'utf8') }));
  // SD カードの中身（disk/）。どれも文字のファイル
  const ddir = path.join(ROOT, 'disk');
  const disk = fs.readdirSync(ddir).sort().map((f) => ({ name: f, contents: fs.readFileSync(path.join(ddir, f), 'latin1') }));
  return `// 自動生成（tools/gen.js が examples/*.asm と disk/ から作る）。手で編集しない。
(function (root) {
  var EXAMPLES = ${JSON.stringify(items, null, 2)};
  var DISK = ${JSON.stringify(disk, null, 2)};
  if (typeof module === 'object' && module.exports) module.exports = { EXAMPLES: EXAMPLES, DISK: DISK };
  else { (root.MyCPU = root.MyCPU || {}).EXAMPLES = EXAMPLES; root.MyCPU.DISK = DISK; }
})(typeof self !== 'undefined' ? self : this);
`;
}

function main() {
  const check = process.argv.includes('--check');
  const ops = loadOpcodes();
  const outputs = {
    'lib/opcodes.js': genOpcodesJs(ops),
    'lib/examples.js': genExamplesJs(),
    'rtl/opcodes.vh': genVh(ops),
  };
  let stale = 0;
  for (const [rel, text] of Object.entries(outputs)) {
    const file = path.join(ROOT, rel);
    const old = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
    if (old === text) continue;
    if (check) { console.error(`古い: ${rel}（node tools/gen.js で作り直す）`); stale++; }
    else { fs.writeFileSync(file, text); console.log(`生成: ${rel}`); }
  }
  if (stale) process.exit(1);
}

if (require.main === module) main();
module.exports = { loadOpcodes, parseCsv };
