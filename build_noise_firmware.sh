#!/bin/bash
# Compile-only candidates. USB bootstrap images contain PRIVATE device keys;
# signed OTA-target images MUST NOT. Nothing is uploaded/flashed by this script.
set -euo pipefail
umask 077 # bootstrap images and build objects may embed private X25519 keys
ROOT="$(cd "$(dirname "$0")" && pwd)"
mode="${1:---bootstrap}"
[[ $# -le 1 && ( "$mode" == --bootstrap || "$mode" == --ota-targets || "$mode" == --demo-next ) ]] || {
  echo "Usage: $0 [--bootstrap|--ota-targets|--demo-next] (COMPILE ONLY, no device upload)" >&2; exit 2;
}
SRC="$ROOT/noise_firmware"
PORT="$ROOT/noise_experiments/noise_probe/src"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
[[ "$(git -C "$ROOT/noise_experiments/noise-c" rev-parse HEAD)" == cfe25410979a87391bb9ac8d4d4bef64e9f268c6 ]] || {
  echo 'Pinned Noise-C checkout missing; run ./build_noise_probe.sh first' >&2; exit 1;
}
[[ -f "$PORT/protocol/handshakestate.c" ]] || { echo 'Run ./build_noise_probe.sh first' >&2; exit 1; }
for role in controller edge1 edge2; do
  case "$role" in
    controller) id=0; version=7;;
    edge1) id=1; version=6;;
    edge2) id=2; version=6;;
  esac
  if [[ "$mode" == --ota-targets ]]; then version=$((version + 1)); fi
  if [[ "$mode" == --demo-next ]]; then version=$((version + 2)); fi
  secret="$ROOT/private_keys/noise/generated/$role.h"
  public="$ROOT/private_keys/noise/generated_public/$role.h"
  [[ -f "$secret" && -f "$public" ]] || { echo "Missing $role local provisioning headers" >&2; exit 1; }
  name="${role}_encrypted_v${version}"
  sketch="$ROOT/noise_experiments/$name"
  rm -rf "$sketch" # ignored generated folder only
  mkdir -p "$sketch"
  cp -R "$PORT" "$sketch/src"
  cp "$SRC/noise_firmware.ino" "$sketch/$name.ino"
  cp "$SRC/NoiseLink.h" "$SRC/NoiseLink.cpp" "$SRC/IdentityStore.h" \
     "$SRC/IdentityStore.cpp" "$ROOT/TrustedPublicKey.h" "$sketch/"
  cp "$public" "$sketch/LinkPublicPins.h" # safe public pins, no private key
  extra=''
  if [[ "$mode" == --bootstrap ]]; then
    cp "$secret" "$sketch/BootstrapPrivate.h" # USB candidate ONLY; contains private key
    cp "$SRC/BootstrapIdentity.cpp" "$sketch/"
    extra=' -DNOISE_USB_BOOTSTRAP=1'
  fi
  output="$ROOT/noise_experiments/${name}_build"
  mkdir -p "$output"
  rm -rf "$output/.arduino-build" # no stale key-bearing object files
  if [[ "$mode" != --bootstrap ]]; then
    rm -f "$output/$name.ino.bin" "$output/$name.ino.bin.manifest" # forbid stale signed artifacts
    [[ ! -e "$sketch/BootstrapPrivate.h" && ! -e "$sketch/BootstrapIdentity.cpp" ]] || exit 1
  fi
  chmod -R go-rwx "$sketch" "$output"
  echo "Compiling $role v$version ($mode; NOT flashing)..."
  "$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" compile -b esp32:esp32:esp32 -j 2 \
    --build-property "compiler.c.extra_flags=-DUSE_LIBSODIUM=1 -Dnoise_init=noisec_init -I$sketch/src -I$sketch/src/protocol" \
    --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=$id -DFW_VERSION=$version$extra -Dnoise_init=noisec_init -I$sketch/src" \
    --build-path "$output/.arduino-build" --output-dir "$output" "$sketch" | tail -3
  chmod -R go-rwx "$sketch" "$output"
  bytes=$(stat -f '%z' "$output/$name.ino.bin")
  echo "$role v$version app image: $bytes / $((0x140000)) OTA slot bytes"
  (( bytes <= 0x140000 )) || { echo "FAIL: $role exceeds OTA slot" >&2; exit 1; }
  nm="$HOME/Library/Arduino15/packages/esp32/tools/esp-x32/2601/bin/xtensa-esp32-elf-nm"
  symbols=$($nm "$output/$name.ino.elf")
  grep -qE ' T verifyRollbackLater$' <<< "$symbols" || { echo 'Rollback deferral hook is not strong' >&2; exit 1; }
  grep -qE ' T _Z27getArduinoLoopTaskStackSizev$' <<< "$symbols" || { echo 'Loop stack override missing' >&2; exit 1; }
  if (( id != 0 )); then
    if ! "$ROOT/.venv/bin/python" - "$output/$name.ino.bin" <<'PY'
from pathlib import Path
import sys
image = Path(sys.argv[1]).read_bytes()
legacy_http = (b'POST image with valid Content-Length', b'GET /register/', b'X-OTA-Manifest')
raise SystemExit(1 if any(marker in image for marker in legacy_http) else 0)
PY
    then echo "FAIL: plaintext HTTP handler linked into $role image" >&2; exit 1; fi
  fi
  image="$output/$name.ino.bin"
  "$ROOT/.venv/bin/python" - "$ROOT" "$image" "$role" "$mode" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:3])
role, mode = sys.argv[3:]
body = image.read_bytes()
present = [name for name in ('controller', 'edge1', 'edge2')
           if (root / 'private_keys/noise' / f'{name}.x25519').read_bytes() in body]
expected = [role] if mode == '--bootstrap' else []
if present != expected:
    raise SystemExit(f'WRONG PRIVATE KEY CONTENT in {mode} image for {role}: {present}; refusing sign/flash')
print('Private identity content check:', 'USB role only' if expected else 'NO PRIVATE KEYS in OTA image')
PY
  if [[ "$mode" != --bootstrap ]]; then
    "$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" sign \
      --private "$ROOT/private_keys/demo.pem" --image "$image" --role "$id" --version "$version"
    "$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
      --public "$ROOT/private_keys/demo_public.bin" --image "$image" \
      --manifest "$image.manifest" --role "$id" --current-version "$((version - 1))"
  fi
  # Rebuildable objects may contain static secrets; remove and save disk.
  # Keep only the needed app/bootloader/partition artifacts and manifest.
  rm -rf "$output/.arduino-build"
  rm -f "$output/$name.ino.elf" "$output/$name.ino.map" "$output/$name.ino.merged.bin"
done
