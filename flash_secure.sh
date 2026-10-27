#!/bin/bash
# One-time trusted USB bootstrap onto a known classic 4 MB ESP32. Requires explicit confirmation.
# Usage: ./flash_secure.sh controller /dev/cu.usbserial-110
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 controller|edge1|edge2 /dev/cu.usbserial-..." >&2; exit 2; }
case "$1" in controller|edge1|edge2) role=$1;; *) echo 'Invalid role' >&2; exit 2;; esac
port=$2
[[ "$port" == /dev/cu.usbserial-* && -e "$port" ]] || { echo 'USB serial port missing' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
ESP="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"
out="$HERE/secure_firmware/${role}_v3"
[[ -f "$out/ota_prototype.ino.bin" ]] || { echo 'Missing secure v3 binary. Run ./build_secure.sh' >&2; exit 1; }
echo 'Reading chip identity without changing firmware...'
info=$("$ESP" --chip esp32 --baud 115200 --no-stub --port "$port" flash-id)
echo "$info" | grep -E 'Chip type:|MAC:|Detected flash size:' | head -3
grep -q 'Detected flash size: 4MB' <<< "$info" || { echo 'Not a confirmed 4MB classic ESP32. STOP.' >&2; exit 1; }
case "$role" in
  controller) expected='20:50:0d:1b:64:d8';;
  edge2) expected='8c:94:df:4c:b7:88';;
  edge1) expected='';;
esac
if [[ -n "$expected" ]] && ! grep -qi "MAC: *$expected" <<< "$info"; then
  echo "Wrong board for $role. STOP." >&2; exit 1
fi
if [[ "$role" == edge1 ]]; then
  echo 'Edge1 MAC has not been checked here. Confirm this is the Micro-USB board.'
fi
echo "About to REPLACE firmware on $port with SIGNED-RECEIVER $role v3."
echo 'All future OTA updates on this board will require matching signed manifests.'
read -r -p 'Type YES to USB-flash this exact board: ' answer
[[ "$answer" == YES ]] || exit 1
"$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" upload \
  -p "$port" -b esp32:esp32:esp32 --board-options UploadSpeed=115200 \
  --input-dir "$out" "$HERE"
echo "Secure-receiver $role v3 flashed. Check status before sending signed v4."
