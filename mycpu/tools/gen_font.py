#!/usr/bin/env python3
# 8×16 ドット × 256 文字のフォントを作る（7.2 のフォント ROM）。
#   python3 tools/gen_font.py [TTF ファイル]
# 出力:
#   font/font8x16.hex … Verilog の $readmemh 用（1 行 1 バイト、文字コード×16＋行、bit7 が左端）
#   lib/font.js       … シミュレータ用（同じ内容）
#   font/preview.png  … 確認用の一覧
# 文字の並びは IBM PC（CP437）。罫線とブロックはドットで描き、ほかは TTF から作る。
import base64
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
TTF = sys.argv[1] if len(sys.argv) > 1 else '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
W, H = 8, 16
BASELINE = 12

# CP437 の 0x01〜0x1F と 0x7F の記号
LOW = '\u0000☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼'

# 罫線：上・下・左・右の線の数（0 / 1 / 2）
BOX = {
    0xB3: (1, 1, 0, 0), 0xB4: (1, 1, 1, 0), 0xB5: (1, 1, 2, 0), 0xB6: (2, 2, 1, 0),
    0xB7: (0, 2, 1, 0), 0xB8: (0, 1, 2, 0), 0xB9: (2, 2, 2, 0), 0xBA: (2, 2, 0, 0),
    0xBB: (0, 2, 2, 0), 0xBC: (2, 0, 2, 0), 0xBD: (2, 0, 1, 0), 0xBE: (1, 0, 2, 0),
    0xBF: (0, 1, 1, 0), 0xC0: (1, 0, 0, 1), 0xC1: (1, 0, 1, 1), 0xC2: (0, 1, 1, 1),
    0xC3: (1, 1, 0, 1), 0xC4: (0, 0, 1, 1), 0xC5: (1, 1, 1, 1), 0xC6: (1, 1, 0, 2),
    0xC7: (2, 2, 0, 1), 0xC8: (2, 0, 0, 2), 0xC9: (0, 2, 0, 2), 0xCA: (2, 0, 2, 2),
    0xCB: (0, 2, 2, 2), 0xCC: (2, 2, 0, 2), 0xCD: (0, 0, 2, 2), 0xCE: (2, 2, 2, 2),
    0xCF: (1, 0, 2, 2), 0xD0: (2, 0, 1, 1), 0xD1: (0, 1, 2, 2), 0xD2: (0, 2, 1, 1),
    0xD3: (2, 0, 0, 1), 0xD4: (1, 0, 0, 2), 0xD5: (0, 1, 0, 2), 0xD6: (0, 2, 0, 1),
    0xD7: (2, 2, 1, 1), 0xD8: (1, 1, 2, 2), 0xD9: (1, 0, 1, 0), 0xDA: (0, 1, 0, 1),
}
CX, CY = 3, 7          # 1 本線の位置
DX, DY = (2, 4), (6, 8)  # 2 本線の位置


def box(u, d, l, r):
    g = [[0] * W for _ in range(H)]
    vx = (CX,) if max(u, d) == 1 else DX
    hy = (CY,) if max(l, r) == 1 else DY
    # 縦の線は横の線の範囲まで、横の線は縦の線の範囲まで伸ばしてつなぐ
    top = min(hy) if (l or r) else CY
    bot = max(hy) if (l or r) else CY
    lef = min(vx) if (u or d) else CX
    rig = max(vx) if (u or d) else CX
    for n, xs, y0, y1 in ((u, DX if u == 2 else (CX,), 0, bot), (d, DX if d == 2 else (CX,), top, H - 1)):
        if n:
            for x in xs:
                for y in range(y0, y1 + 1):
                    g[y][x] = 1
    for n, ys, x0, x1 in ((l, DY if l == 2 else (CY,), 0, rig), (r, DY if r == 2 else (CY,), lef, W - 1)):
        if n:
            for y in ys:
                for x in range(x0, x1 + 1):
                    g[y][x] = 1
    return g


def block(code):
    g = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if code == 0xB0: v = (x % 4 == 0 and y % 2 == 0) or (x % 4 == 2 and y % 2 == 1)
            elif code == 0xB1: v = (x + y) % 2 == 0
            elif code == 0xB2: v = not ((x % 4 == 0 and y % 2 == 0) or (x % 4 == 2 and y % 2 == 1))
            elif code == 0xDB: v = True
            elif code == 0xDC: v = y >= 8
            elif code == 0xDD: v = x < 4
            elif code == 0xDE: v = x >= 4
            elif code == 0xDF: v = y < 8
            elif code == 0xFE: v = 2 <= x <= 5 and 5 <= y <= 10
            g[y][x] = 1 if v else 0
    return g


def char_of(code):
    if code < 0x20:
        return LOW[code]
    if code == 0x7F:
        return '⌂'
    return bytes([code]).decode('cp437')


def glyph(font, code):
    if code in BOX:
        return box(*BOX[code])
    if code in (0xB0, 0xB1, 0xB2, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xFE):
        return block(code)
    ch = char_of(code)
    img = Image.new('L', (W, H), 0)
    if ch.strip() and ch != '\u0000':
        ImageDraw.Draw(img).text((0, BASELINE), ch, font=font, fill=255, anchor='ls')
    return [[1 if img.getpixel((x, y)) >= 110 else 0 for x in range(W)] for y in range(H)]


def main():
    font = ImageFont.truetype(TTF, 13)
    data = bytearray()
    sheet = Image.new('L', (32 * (W + 1), 8 * (H + 1)), 40)
    for code in range(256):
        g = glyph(font, code)
        for y in range(H):
            data.append(sum(g[y][x] << (7 - x) for x in range(W)))
            for x in range(W):
                if g[y][x]:
                    sheet.putpixel(((code % 32) * (W + 1) + x, (code // 32) * (H + 1) + y), 255)
    with open(os.path.join(ROOT, 'font', 'font8x16.hex'), 'w') as f:
        f.write('\n'.join('%02X' % b for b in data) + '\n')
    b64 = base64.b64encode(bytes(data)).decode()
    with open(os.path.join(ROOT, 'lib', 'font.js'), 'w') as f:
        f.write('// 自動生成（tools/gen_font.py が作る）。8×16 ドット × 256 文字、1 バイト = 1 行、bit7 が左端。\n')
        f.write('(function (root) {\n')
        f.write("  var B64 = '%s';\n" % b64)
        f.write("  var bin = typeof atob === 'function' ? atob(B64) : Buffer.from(B64, 'base64').toString('binary');\n")
        f.write('  var FONT = new Uint8Array(bin.length);\n')
        f.write('  for (var i = 0; i < bin.length; i++) FONT[i] = bin.charCodeAt(i);\n')
        f.write("  if (typeof module === 'object' && module.exports) module.exports = FONT;\n")
        f.write('  else (root.MyCPU = root.MyCPU || {}).FONT = FONT;\n')
        f.write("})(typeof self !== 'undefined' ? self : this);\n")
    sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST).save(os.path.join(ROOT, 'font', 'preview.png'))
    print('font/font8x16.hex, lib/font.js, font/preview.png')


main()
