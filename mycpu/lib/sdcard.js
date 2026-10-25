// SD カード（SPI モード）のふり。シミュレータ用。Verilog のテストベンチの tb/sd_model.v と同じ動きにしてある。
//   var sd = new SDCard(disk);  // disk = { sectors: 総セクタ数, read(lba) → Uint8Array(512) }
//   sd.exchange(byte) → byte    // CS を有効にしたまま 1 バイト送って 1 バイト受け取る
//   sd.deselect()               // CS を無効にした
// 対応しているコマンド：CMD0・CMD8・CMD55＋ACMD41・CMD58・CMD16・CMD17（1 セクタ読み出し）。
// SDHC（セクタ番号で指定）として振る舞う。書き込み（CMD24）はまだ。
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.MyCPU.SDCard = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function SDCard(disk) {
    this.disk = disk;
    this.idle = true;      // CMD0 の後、ACMD41 で初期化が終わるまで
    this.app = false;      // 直前が CMD55
    this.acmd41 = 0;       // ACMD41 を受けた回数（2 回目で初期化完了）
    this.cmd = [];
    this.out = [];
  }

  SDCard.prototype.deselect = function () {
    this.cmd = [];
    this.out = [];
  };

  SDCard.prototype.exchange = function (b) {
    var r = this.out.length ? this.out.shift() : 0xFF;
    this.receive(b & 0xFF);
    return r;
  };

  SDCard.prototype.receive = function (b) {
    if (!this.cmd.length) {
      if ((b & 0xC0) !== 0x40) return;   // コマンドの始まりを待つ
    }
    this.cmd.push(b);
    if (this.cmd.length < 6) return;
    var c = this.cmd;
    this.cmd = [];
    this.command(c[0] & 0x3F, ((c[1] << 24) | (c[2] << 16) | (c[3] << 8) | c[4]) >>> 0);
  };

  SDCard.prototype.command = function (cmd, arg) {
    var app = this.app, out = [0xFF], i;   // 応答の前に 1 バイト待たせる
    var r1 = this.idle ? 0x01 : 0x00;
    this.app = false;
    if (app && cmd === 41) {
      if (++this.acmd41 >= 2) this.idle = false;
      out.push(this.idle ? 0x01 : 0x00);
    } else switch (cmd) {
      case 0:
        this.idle = true;
        this.acmd41 = 0;
        out.push(0x01);
        break;
      case 8:
        out.push(r1, 0x00, 0x00, (arg >> 8) & 0x0F, arg & 0xFF);
        break;
      case 55:
        this.app = true;
        out.push(r1);
        break;
      case 58:
        out.push(r1, 0xC0, 0xFF, 0x80, 0x00);   // 電源 OK・SDHC
        break;
      case 16:
        out.push(r1);
        break;
      case 17:
        if (this.idle) { out.push(0x05); break; }
        if (arg >= this.disk.sectors) { out.push(0x40); break; }   // 範囲外
        out.push(0x00, 0xFF, 0xFF, 0xFE);
        var data = this.disk.read(arg);
        for (i = 0; i < 512; i++) out.push(data[i]);
        out.push(0xFF, 0xFF);   // CRC（確かめない）
        break;
      default:
        out.push(r1 | 0x04);   // 知らないコマンド
    }
    this.out = this.out.concat(out);
  };

  return SDCard;
});
