#!/bin/bash
# DANGEROUS: one-device-at-a-time USB trust bootstrap for role-keyed Noise OTA.
# NEVER run unattended. Back up local private_keys/noise/ securely before use.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 controller|edge1|edge2 /dev/cu.usbserial-..." >&2; exit 2; }
case "$1" in
  controller) role=controller; expected='20:50:0d:1b:64:d8'; version=7;;
  edge1) role=edge1; expected='a4:f0:0f:66:5a:18'; version=6;;
  edge2) role=edge2; expected='8c:94:df:4c:b7:88'; version=6;;
  *) echo 'Invalid role' >&2; exit 2;;
esac
port=$2
[[ "$port" == /dev/cu.usbserial-* && -e "$port" ]] || { echo 'Missing expected USB serial port' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ "$(git -C "$ROOT" branch --show-current)" == feature/noise-link ]] || {
  echo 'Refusing to flash outside feature/noise-link branch' >&2; exit 1;
}
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
ESP="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"
name="${role}_encrypted_v${version}"
out="$ROOT/noise_experiments/${name}_build"
sketch="$ROOT/noise_experiments/$name"
image="$out/$name.ino.bin"
secret="$ROOT/private_keys/noise/generated/$role.h"
public="$ROOT/private_keys/noise/generated_public/$role.h"
for path in "$image" "$out/$name.ino.bootloader.bin" "$out/$name.ino.partitions.bin" \
            "$secret" "$public" "$sketch/$name.ino" "$sketch/NoiseLink.cpp" \
            "$sketch/BootstrapPrivate.h" "$sketch/LinkPublicPins.h"; do
  [[ -f "$path" ]] || { echo "Missing $path; first compile with ./build_noise_firmware.sh" >&2; exit 1; }
done
for pair in "$ROOT/noise_firmware/noise_firmware.ino:$sketch/$name.ino" \
            "$ROOT/noise_firmware/NoiseLink.cpp:$sketch/NoiseLink.cpp" \
            "$ROOT/noise_firmware/NoiseLink.h:$sketch/NoiseLink.h" \
            "$ROOT/noise_firmware/IdentityStore.cpp:$sketch/IdentityStore.cpp" \
            "$ROOT/noise_firmware/IdentityStore.h:$sketch/IdentityStore.h" \
            "$ROOT/noise_firmware/BootstrapIdentity.cpp:$sketch/BootstrapIdentity.cpp" \
            "$ROOT/TrustedPublicKey.h:$sketch/TrustedPublicKey.h" \
            "$secret:$sketch/BootstrapPrivate.h" \
            "$public:$sketch/LinkPublicPins.h"; do
  cmp -s "${pair%%:*}" "${pair#*:}" || { echo 'Stale image/source/identity; rebuild first.' >&2; exit 1; }
done
diff -qr "$ROOT/noise_experiments/noise_probe/src" "$sketch/src" >/dev/null || {
  echo 'Stale or altered Noise-C port; rebuild and review first.' >&2; exit 1;
}
[[ "$image" -nt "$sketch/$name.ino" && "$image" -nt "$sketch/NoiseLink.cpp" &&
   "$image" -nt "$sketch/BootstrapPrivate.h" && "$image" -nt "$sketch/IdentityStore.cpp" ]] || {
  echo 'Stale binary; rebuild first.' >&2; exit 1;
}
bytes=$(stat -f '%z' "$image")
(( bytes <= 0x140000 && bytes > 0 )) || { echo 'Wrong size for 1.25 MB OTA slot' >&2; exit 1; }
"$ROOT/.venv/bin/python" - "$ROOT" "$image" "$role" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:3])
role = sys.argv[3]
body = image.read_bytes()
present = [r for r in ('controller', 'edge1', 'edge2')
           if (root / 'private_keys/noise' / f'{r}.x25519').read_bytes() in body]
if present != [role]:
    raise SystemExit('Wrong key-bearing USB image: refusing to flash')
PY
echo 'Reading physical ESP32 identity; no firmware changed yet...'
info=$("$ESP" --chip esp32 --baud 115200 --no-stub --port "$port" flash-id)
echo "$info" | grep -E 'Chip type:|MAC:|Detected flash size:' | head -3
grep -q 'Chip type: *ESP32-' <<< "$info" || { echo 'Not classic ESP32' >&2; exit 1; }
grep -q 'Detected flash size: 4MB' <<< "$info" || { echo 'Flash size is not 4MB' >&2; exit 1; }
grep -qi "MAC: *$expected" <<< "$info" || { echo "Wrong board: expected $role $expected" >&2; exit 1; }
shasum -a 256 "$image" | awk '{print "Candidate image SHA-256: " $1}'
pmset -g batt | head -2
printf '\nThis USB FLASH REPLACES %s firmware with PRIVATE-KEY-BEARING encrypted v%d.\n' "$role" "$version"
echo 'USB bootstrap provisions this role key into NVS. Later signed OTA binaries contain NO private key.'
echo 'Check independent encrypted backup of private_keys/noise/; do not send USB image or keys to GitHub.'
echo 'Expect other boards to be unreachable until every role is bootstrapped.'
read -r -p 'Type BACKED_UP if the identities have been backed up securely: ' backed
[[ "$backed" == BACKED_UP ]] || exit 1
read -r -p "Type YES to FLASH this exact $expected board: " answer
[[ "$answer" == YES ]] || exit 1
"$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" upload \
  -p "$port" -b esp32:esp32:esp32 --board-options UploadSpeed=115200 \
  --input-dir "$out" "$sketch"
echo "Encrypted $role v$version USB write completed; runtime status is NOT yet verified."
