#!/bin/bash
# COMPILE + SIGN ONLY. New edge v9 candidates; never touch prepared edge v8 images or any board.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
PORT="$ROOT/noise_experiments/noise_probe/src"
[[ -f "$PORT/protocol/handshakestate.c" &&
   "$(git -C "$ROOT/noise_experiments/noise-c" rev-parse HEAD)" == cfe25410979a87391bb9ac8d4d4bef64e9f268c6 ]] || {
  echo 'Pinned Noise-C port missing or changed; STOP' >&2; exit 1;
}
for role in edge1 edge2; do
  [[ "$role" == edge1 ]] && id=1 || id=2
  name="${role}_reconnect_v9"
  sketch="$ROOT/noise_experiments/$name"
  out="$ROOT/noise_experiments/${name}_build"
  mkdir -p "$sketch" "$out"
  rm -rf "$sketch/src" "$out/.arduino-build" # only this ignored candidate
  cp -R "$PORT" "$sketch/src"
  cp "$ROOT/noise_firmware/noise_firmware.ino" "$sketch/$name.ino"
  cp "$ROOT/noise_firmware/"{NoiseLink.cpp,NoiseLink.h,IdentityStore.cpp,IdentityStore.h} \
     "$ROOT/TrustedPublicKey.h" "$sketch/"
  cp "$ROOT/private_keys/noise/generated_public/$role.h" "$sketch/LinkPublicPins.h"
  [[ ! -e "$sketch/BootstrapPrivate.h" && ! -e "$sketch/BootstrapIdentity.cpp" ]] || {
    echo 'STOP: provisioning private key in OTA candidate source' >&2; exit 1;
  }
  "$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" compile -b esp32:esp32:esp32 -j 2 \
    --build-property "compiler.c.extra_flags=-DUSE_LIBSODIUM=1 -Dnoise_init=noisec_init -I$sketch/src -I$sketch/src/protocol" \
    --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=$id -DFW_VERSION=9 -Dnoise_init=noisec_init -I$sketch/src" \
    --build-path "$out/.arduino-build" --output-dir "$out" "$sketch" | tail -3
  image="$out/$name.ino.bin"
  ROOT="$ROOT" IMAGE="$image" "$ROOT/.venv/bin/python" - <<'PY'
from pathlib import Path
import os
root, image = Path(os.environ['ROOT']), Path(os.environ['IMAGE'])
data = image.read_bytes()
assert len(data) <= 0x140000, 'OTA slot exceeded'
for role in ('controller', 'edge1', 'edge2'):
    secret = (root / 'private_keys/noise' / f'{role}.x25519').read_bytes()
    assert len(secret) == 32 and secret not in data, 'Private Noise identity in candidate!'
for marker in (b'POST image with valid Content-Length', b'GET /register/', b'X-OTA-Manifest'):
    assert marker not in data, 'Legacy edge HTTP handler in candidate!'
print(f'Key-free reconnect candidate: {len(data)} / {0x140000} OTA slot bytes')
PY
  "$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" sign \
    --private "$ROOT/private_keys/demo.pem" --image "$image" --role "$id" --version 9
  "$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
    --public "$ROOT/private_keys/demo_public.bin" --image "$image" \
    --manifest "$image.manifest" --role "$id" --current-version 8
  chmod -R go-rwx "$sketch" "$out"
  rm -rf "$out/.arduino-build"
  rm -f "$out/$name.ino.elf" "$out/$name.ino.map" "$out/$name.ino.merged.bin"
done
echo 'Two v9 signed candidates built LOCALLY ONLY. Existing prepared v8 edge images unchanged.'
