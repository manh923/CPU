// FAT16 / FAT32 のディスクイメージを作る（SD カードの中身と同じ形：MBR ＋ パーティション 1 つ）。
//   var disk = buildDisk(files, { type: 'fat16' | 'fat32', sizeMB, spc, partStart, label, date });
//     files = [{ name: 'HELLO.EXE', data: Uint8Array, longName?: 'hello-world.exe' }]
//   disk.sectors / disk.read(lba) → Uint8Array(512) / disk.toBuffer() → Uint8Array（イメージ全体）
// 中身のあるセクタだけ覚えておくので、大きなイメージでも軽い。
// ファイルはルートディレクトリに置く。longName を付けると長いファイル名（LFN）の項目も書く。
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.MyCPU.fat = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function SparseDisk(sectors) {
    this.sectors = sectors;
    this.map = new Map();
  }
  SparseDisk.prototype.sector = function (lba) {
    var s = this.map.get(lba);
    if (!s) { s = new Uint8Array(512); this.map.set(lba, s); }
    return s;
  };
  SparseDisk.prototype.read = function (lba) {
    return this.map.get(lba) || new Uint8Array(512);
  };
  SparseDisk.prototype.write = function (lba, off, bytes) {
    for (var i = 0; i < bytes.length; i++) {
      var p = off + i;
      this.sector(lba + (p >> 9))[p & 511] = bytes[i];
    }
  };
  SparseDisk.prototype.writeSector = function (lba, data) {
    this.sector(lba).set(data);
  };
  SparseDisk.prototype.toBuffer = function () {
    var buf = new Uint8Array(this.sectors * 512);
    this.map.forEach(function (s, lba) { buf.set(s, lba * 512); });
    return buf;
  };

  // ファイルからの読み込み（.img をそのまま SD カードにする）
  function bufferDisk(buf) {
    return {
      sectors: Math.floor(buf.length / 512),
      read: function (lba) { return buf.subarray(lba * 512, lba * 512 + 512); },
      writeSector: function (lba, data) { buf.set(data, lba * 512); },
      buffer: buf,
    };
  }

  function le(n, v) {
    var out = [];
    for (var i = 0; i < n; i++) out.push(Number((BigInt(v) >> BigInt(8 * i)) & 0xFFn));
    return out;
  }
  function ascii(s, n) {
    var out = [];
    for (var i = 0; i < n; i++) out.push(i < s.length ? s.charCodeAt(i) : 0x20);
    return out;
  }

  // "README.TXT" → 11 バイトの 8.3 形式（"README  TXT"）
  function shortName(name) {
    var m = /^([^.]{1,8})(?:\.([^.]{1,3}))?$/.exec(name.toUpperCase());
    if (!m) throw new Error('8.3 形式でないファイル名: ' + name);
    return ascii(m[1], 8).concat(ascii(m[2] || '', 3));
  }

  function lfnChecksum(sn) {
    var sum = 0;
    for (var i = 0; i < 11; i++) sum = (((sum & 1) << 7) | (sum >> 1)) + sn[i] & 0xFF;
    return sum;
  }

  // 長いファイル名の項目（後ろの部分から順に並べる）
  function lfnEntries(longName, sn) {
    var chars = [];
    for (var i = 0; i < longName.length; i++) chars.push(longName.charCodeAt(i));
    chars.push(0);
    while (chars.length % 13) chars.push(0xFFFF);
    var n = chars.length / 13, sum = lfnChecksum(sn), out = [];
    for (var k = n; k >= 1; k--) {
      var part = chars.slice((k - 1) * 13, k * 13), e = new Array(32).fill(0);
      e[0] = k | (k === n ? 0x40 : 0);
      e[11] = 0x0F; e[13] = sum;
      var pos = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30];
      for (var j = 0; j < 13; j++) { e[pos[j]] = part[j] & 0xFF; e[pos[j] + 1] = part[j] >> 8; }
      out.push(e);
    }
    return out;
  }

  function fatDate(d) {
    return ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
  }
  function fatTime(d) {
    return (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
  }

  function buildDisk(files, opts) {
    opts = opts || {};
    var type = opts.type || 'fat16';
    var fat32 = type === 'fat32';
    var spc = opts.spc || (fat32 ? 1 : 4);
    var partStart = opts.partStart != null ? opts.partStart : 2048;
    var sizeMB = opts.sizeMB || (fat32 ? 40 : 16);
    var label = (opts.label || 'MYCPU').toUpperCase();
    var date = opts.date || new Date(2026, 9, 25, 12, 0, 0);
    var serial = opts.serial != null ? opts.serial : 0x20261025;
    var total = opts.totalSectors || Math.floor(sizeMB * 1024 * 1024 / 512) - partStart;
    var reserved = fat32 ? 32 : 1, nfats = 2, rootEnts = fat32 ? 0 : 512;
    var rootSecs = (rootEnts * 32 + 511) >> 9;
    var esize = fat32 ? 4 : 2;

    // FAT の大きさとクラスタ数を決める（FAT を大きくするとデータ領域が減るので、落ち着くまで繰り返す）
    var fatSz = 1, clusters;
    for (;;) {
      clusters = Math.floor((total - reserved - nfats * fatSz - rootSecs) / spc);
      var need = Math.ceil((clusters + 2) * esize / 512);
      if (need <= fatSz) break;
      fatSz = need;
    }
    if (fat32 ? clusters < 65525 : clusters < 4085 || clusters > 65524) {
      throw new Error(type + ' にはクラスタ数 ' + clusters + ' が合わない（大きさかクラスタの大きさを変える）');
    }

    var disk = new SparseDisk(partStart + total);
    var fatLba = partStart + reserved;
    var rootLba = fatLba + nfats * fatSz;
    var dataLba = rootLba + rootSecs;

    // MBR：パーティション 1 つ（FAT16 は 0x06、FAT32（LBA）は 0x0C）
    var mbr = new Array(16).fill(0);
    mbr[4] = fat32 ? 0x0C : 0x06;
    mbr = mbr.map(function (v, i) { return i >= 8 && i < 12 ? le(4, partStart)[i - 8] : i >= 12 ? le(4, total)[i - 12] : v; });
    if (partStart > 0) {
      disk.write(0, 0x1BE, mbr);
      disk.write(0, 510, [0x55, 0xAA]);
    }

    // ブートセクタ（BPB）
    var bs = [0xEB, fat32 ? 0x58 : 0x3C, 0x90].concat(ascii('MYCPU', 8),
      le(2, 512), [spc], le(2, reserved), [nfats], le(2, rootEnts),
      le(2, !fat32 && total < 65536 ? total : 0), [0xF8], le(2, fat32 ? 0 : fatSz),
      le(2, 63), le(2, 255), le(4, partStart), le(4, !fat32 && total < 65536 ? 0 : total));
    if (fat32) {
      bs = bs.concat(le(4, fatSz), le(2, 0), le(2, 0), le(4, 2), le(2, 1), le(2, 6), new Array(12).fill(0),
        [0x80, 0, 0x29], le(4, serial), ascii(label, 11), ascii('FAT32', 8));
    } else {
      bs = bs.concat([0x80, 0, 0x29], le(4, serial), ascii(label, 11), ascii('FAT16', 8));
    }
    disk.write(partStart, 0, bs);
    disk.write(partStart, 510, [0x55, 0xAA]);

    // ファイルをクラスタに並べる（FAT32 はクラスタ 2 がルートディレクトリ）
    var fat = [fat32 ? 0x0FFFFFF8 : 0xFFF8, fat32 ? 0x0FFFFFFF : 0xFFFF];
    var EOC = fat32 ? 0x0FFFFFFF : 0xFFFF;
    var next = 2;
    function alloc(nclus) {
      var first = next;
      for (var i = 0; i < nclus; i++) fat[next + i] = i === nclus - 1 ? EOC : next + i + 1;
      next += nclus;
      return first;
    }
    function clusLba(c) { return dataLba + (c - 2) * spc; }

    var entries = [];
    var vol = ascii(label, 11).concat([0x08], new Array(20).fill(0));
    entries.push(vol);
    var rootClus = 0;
    var dirBytes = (files.length * 4 + 2) * 32;  // LFN の分も見込んでおく
    if (fat32) rootClus = alloc(Math.ceil(dirBytes / (spc * 512)));

    files.forEach(function (f) {
      var sn = shortName(f.name);
      if (f.longName) lfnEntries(f.longName, sn).forEach(function (e) { entries.push(e); });
      var size = f.data.length;
      var first = size ? alloc(Math.ceil(size / (spc * 512))) : 0;
      if (first) disk.write(clusLba(first), 0, f.data);
      var d = f.date || date;
      entries.push(sn.concat([0x20, 0, 0], le(2, fatTime(d)), le(2, fatDate(d)), le(2, fatDate(d)),
        le(2, first >> 16), le(2, fatTime(d)), le(2, fatDate(d)), le(2, first & 0xFFFF), le(4, size)));
    });
    if (next - 2 > clusters) throw new Error('ファイルが入りきらない');

    var dirData = [].concat.apply([], entries);
    if (fat32) disk.write(clusLba(rootClus), 0, dirData);
    else {
      if (entries.length > rootEnts) throw new Error('ルートディレクトリがいっぱい');
      disk.write(rootLba, 0, dirData);
    }

    // FAT（2 つとも同じ）
    var fatBytes = [];
    fat.forEach(function (v) { fatBytes = fatBytes.concat(le(esize, v)); });
    for (var k = 0; k < nfats; k++) disk.write(fatLba + k * fatSz, 0, fatBytes);

    if (fat32) {
      // FSInfo（空きクラスタ数）とブートセクタの控え
      var free = clusters - (next - 2);
      var fsi = new Array(512).fill(0);
      le(4, 0x41615252).forEach(function (v, i) { fsi[i] = v; });
      le(4, 0x61417272).forEach(function (v, i) { fsi[484 + i] = v; });
      le(4, free).forEach(function (v, i) { fsi[488 + i] = v; });
      le(4, next).forEach(function (v, i) { fsi[492 + i] = v; });
      fsi[510] = 0x55; fsi[511] = 0xAA;
      disk.write(partStart + 1, 0, fsi);
      disk.write(partStart + 6, 0, bs);
      disk.write(partStart + 6, 510, [0x55, 0xAA]);
    }

    disk.info = { type: type, clusters: clusters, spc: spc, fatLba: fatLba, rootLba: rootLba, dataLba: dataLba,
      usedClusters: next - 2, partStart: partStart, total: total };
    return disk;
  }

  return { buildDisk: buildDisk, bufferDisk: bufferDisk, shortName: shortName };
});
