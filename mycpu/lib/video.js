// テキスト VRAM を絵にする（7.1）。Verilog の表示回路と同じ規則で描く。
//   1 文字 2 バイト：偶数番地 = 文字コード、奇数番地 = 色（下位 4bit 文字色、上位 4bit 背景色）
//   160 × 45 文字、1 文字 8 × 16 ドット → 1280 × 720
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./isa.js'), require('./font.js'));
  else root.MyCPU.video = factory(root.MyCPU.isa, root.MyCPU.FONT);
})(typeof self !== 'undefined' ? self : this, function (isa, FONT) {
  'use strict';
  var T = isa.TEXT;
  var WIDTH = T.COLS * T.CELL_W, HEIGHT = T.ROWS * T.CELL_H;

  // 標準の 16 色（CGA / VGA と同じ）
  var PALETTE = [
    [0x00, 0x00, 0x00], [0x00, 0x00, 0xAA], [0x00, 0xAA, 0x00], [0x00, 0xAA, 0xAA],
    [0xAA, 0x00, 0x00], [0xAA, 0x00, 0xAA], [0xAA, 0x55, 0x00], [0xAA, 0xAA, 0xAA],
    [0x55, 0x55, 0x55], [0x55, 0x55, 0xFF], [0x55, 0xFF, 0x55], [0x55, 0xFF, 0xFF],
    [0xFF, 0x55, 0x55], [0xFF, 0x55, 0xFF], [0xFF, 0xFF, 0x55], [0xFF, 0xFF, 0xFF],
  ];

  // 1 文字を描く。out は 1 画素 stride バイト（RGB なら 3、canvas の RGBA なら 4）
  function drawCell(vram, cell, out, stride) {
    var ch = vram[cell * 2], attr = vram[cell * 2 + 1];
    var fg = PALETTE[attr & 15], bg = PALETTE[attr >> 4];
    var cx = (cell % T.COLS) * T.CELL_W, cy = Math.floor(cell / T.COLS) * T.CELL_H;
    for (var y = 0; y < T.CELL_H; y++) {
      var bits = FONT[ch * 16 + y], o = ((cy + y) * WIDTH + cx) * stride;
      for (var x = 0; x < T.CELL_W; x++, o += stride) {
        var c = (bits >> (7 - x)) & 1 ? fg : bg;
        out[o] = c[0]; out[o + 1] = c[1]; out[o + 2] = c[2];
        if (stride === 4) out[o + 3] = 255;
      }
    }
  }

  function render(vram, out, stride) {
    stride = stride || 3;
    out = out || new Uint8Array(WIDTH * HEIGHT * stride);
    for (var i = 0; i < T.COLS * T.ROWS; i++) drawCell(vram, i, out, stride);
    return out;
  }

  // 文字だけを取り出す（テストや端末表示用）
  function text(vram) {
    var lines = [];
    for (var r = 0; r < T.ROWS; r++) {
      var s = '';
      for (var c = 0; c < T.COLS; c++) {
        var ch = vram[(r * T.COLS + c) * 2];
        s += ch >= 0x20 && ch < 0x7f ? String.fromCharCode(ch) : ' ';
      }
      lines.push(s.replace(/\s+$/, ''));
    }
    while (lines.length && lines[lines.length - 1] === '') lines.pop();
    return lines.join('\n');
  }

  return { WIDTH: WIDTH, HEIGHT: HEIGHT, PALETTE: PALETTE, drawCell: drawCell, render: render, text: text };
});
