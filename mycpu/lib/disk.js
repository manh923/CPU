// SD カードに入れるファイルを作る（Node・ブラウザ共通）。
//   makeFile(name, contents)：NAME.exe.asm → NAME.EXE、NAME.com.asm → NAME.COM（0x26000 から）、
//                             NAME.sys.asm → NAME.SYS（0x20000 から。MYDOS.SYS 用）。アセンブルして作る。ほかはそのまま
//   makeDisk(sources, opts)：ファイルを並べて FAT のディスクイメージにする（lib/fat.js）
// .EXE：'MZ'、ヘッダの大きさ（16）、読み込む番地、開始番地（ラベル start、なければ読み込む番地）、本体の大きさ、本体
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./assembler.js'), require('./fat.js'));
  else root.MyCPU.disk = factory(root.MyCPU.Assembler, root.MyCPU.fat);
})(typeof self !== 'undefined' ? self : this, function (Assembler, fat) {
  'use strict';
  var TPA = 0x26000, SYS_BASE = 0x20000;

  function le32(v) { return [v & 0xFF, (v >>> 8) & 0xFF, (v >>> 16) & 0xFF, (v >>> 24) & 0xFF]; }

  function toBytes(contents) {
    if (typeof contents !== 'string') return new Uint8Array(contents);
    var out = new Uint8Array(contents.length);
    for (var i = 0; i < contents.length; i++) out[i] = contents.charCodeAt(i) & 0xFF;
    return out;
  }

  function makeFile(name, contents) {
    var m = /^(.+)\.(exe|com|sys)\.asm$/i.exec(name);
    if (!m) return { name: name.toUpperCase(), data: toBytes(contents) };
    var source = typeof contents === 'string' ? contents : new TextDecoder().decode(contents);
    var r = Assembler.assemble(source);
    var kind = m[2].toLowerCase(), base = kind === 'sys' ? SYS_BASE : TPA;
    if (r.image.length <= base) throw new Error(name + '：.org 0x' + base.toString(16) + ' から書く');
    var body = r.image.subarray(base);
    var outName = (m[1] + '.' + m[2]).toUpperCase();
    if (kind !== 'exe') return { name: outName, data: new Uint8Array(body) };
    var entry = r.symbols.has('start') ? Number(r.symbols.get('start')) : TPA;
    var head = [0x4D, 0x5A, 16, 0].concat(le32(TPA), le32(entry), le32(body.length));
    var data = new Uint8Array(16 + body.length);
    data.set(head, 0);
    data.set(body, 16);
    return { name: outName, data: data };
  }

  // sources = [{ name, contents }]（contents は文字列か Uint8Array）
  function makeDisk(sources, opts) {
    var files = sources.map(function (s) { return makeFile(s.name, s.contents); });
    return fat.buildDisk(files, opts);
  }

  return { TPA: TPA, makeFile: makeFile, makeDisk: makeDisk };
});
