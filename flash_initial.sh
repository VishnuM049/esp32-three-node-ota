#!/bin/bash
# One-time bootstrap over USB, for a new 4 MB classic ESP32 board.
# Usage: ./flash_initial.sh edge1 /dev/cu.usbserial-10
#        ./flash_initial.sh edge2 /dev/cu.usbserial-110
set -euo pipefail
if (( $# != 2 )); then echo "Usage: $0 controller|edge1|edge2 /dev/cu.usbserial-..." >&2; exit 2; fi
case "$1" in controller|edge1|edge2) role=$1;; *) echo 'Unknown role' >&2; exit 2;; esac
port=$2
[[ "$port" == /dev/cu.usbserial-* && -e "$port" ]] || { echo 'USB serial port not found' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
ESPTOOL="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"
BIN="$HERE/firmware/${role}_v1/ota_prototype.ino.bin"
[[ -f "$BIN" ]] || { echo "Missing $BIN; run build_all.sh" >&2; exit 2; }
echo 'Checking chip and flash size (read-only)...'
info=$("$ESPTOOL" --chip esp32 --port "$port" flash-id)
echo "$info" | grep -E 'Chip type:|Detected flash size:'
grep -q 'Detected flash size: 4MB' <<< "$info" || { echo 'Not a detected 4 MB ESP32; STOP. Check partition scheme first.' >&2; exit 1; }
echo "About to replace firmware on $port with $role v1."
read -r -p 'Type YES to flash this board: ' answer
[[ "$answer" == YES ]] || exit 1
"$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" upload \
  -p "$port" -b esp32:esp32:esp32 --board-options UploadSpeed=115200 \
  --input-dir "$HERE/firmware/${role}_v1" "$HERE"
echo "Done: $role v1. Now power this board; do not reflash it with another role."
