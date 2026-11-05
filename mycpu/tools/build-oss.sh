#!/bin/sh
# Tang Nano 20K の書き込みファイル（.fs）を、オープンソースのツールで作る（Gowin EDA の代わり）。
#   準備：pip install yowasp-yosys yowasp-nextpnr-himbaechel-gowin apycula
#   使い方：sh tools/build-oss.sh [出力先のフォルダ]   （省略すると build-oss/）。できるのは mycpu_tn20k.fs
#   書き込み：openFPGALoader -b tangnano20k mycpu_tn20k.fs（SRAM へ。-f を付けるとフラッシュへ）、または Gowin Programmer
# Gowin EDA との違い：
#   ・HDMI の出力は ELVDS_OBUF ではなく TLVDS_OBUF（Apicula の Tang Nano 20K の HDMI の例と同じ）。トップを写して置き換える
#   ・ピンは rtl/gowin/tangnano20k_oss.cst（内蔵 SDRAM と HDMI の n 側も書いてある）
#   ・タイミングが 27MHz に届かなくても .fs を作る（--timing-allow-fail）。nextpnr の見積もりは今のところ約 22MHz
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-build-oss}
mkdir -p "$OUT/rtl"
cd "$OUT"
YOSYS=${YOSYS:-yowasp-yosys}
NEXTPNR=${NEXTPNR:-yowasp-nextpnr-himbaechel-gowin}
PACK=${PACK:-gowin_pack}

# ROM（BIOS）とフォントの中身。合成ツールが $readmemh でこのフォルダから読む
node "$ROOT/asm/asm.js" "$ROOT/examples/bios.asm" -o rom
cp "$ROOT/font/font8x16.hex" .

# RTL を写す（相対パスで読む。YoWASP は作業フォルダの外のファイルを読めないことがある）
cp "$ROOT"/rtl/*.v "$ROOT"/rtl/*.vh rtl/
sed 's/ELVDS_OBUF/TLVDS_OBUF/' "$ROOT/rtl/gowin/top_tangnano20k.v" > rtl/top_oss.v
cp "$ROOT/rtl/gowin/tangnano20k_oss.cst" .

$YOSYS -q -l synth.log -p "read_verilog -defer -Irtl rtl/top_oss.v rtl/cpu.v rtl/soc.v rtl/sdram.v rtl/uart.v rtl/video.v rtl/tmds.v; \
  hierarchy -top top_tangnano20k; synth_gowin -family gw2a -top top_tangnano20k -json synth.json"
$NEXTPNR --json synth.json --write pnr.json --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
  --vopt cst=tangnano20k_oss.cst --freq 27 --timing-allow-fail -l pnr.log
$PACK -d GW2A-18C -o mycpu_tn20k.fs pnr.json
echo "できた：$OUT/mycpu_tn20k.fs"
grep -E "Max frequency" pnr.log | tail -2
