#!/bin/bash
# USB v10 + key-free OTA v11 candidates. NEVER flashes or uploads. v11 is signed locally.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"
mode="${1:---ota}"
[[ $# -le 1 && ( "$mode" == --ota || "$mode" == --usb || "$mode" == --ota-v11 || "$mode" == --demo-v12 ) ]] || { echo 'Usage: build_https_candidate.sh [--ota|--usb|--ota-v11|--demo-v12]' >&2; exit 2; }
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
PORT="$ROOT/noise_experiments/noise_probe/src"
[[ -f "$PORT/protocol/handshakestate.c" ]] || { echo 'Pinned local Noise-C missing' >&2; exit 1; }
version=10
name=https_controller_v10_candidate
[[ "$mode" == --usb ]] && name=https_controller_v10_usb_private
if [[ "$mode" == --ota-v11 ]]; then version=11; name=https_controller_v11_candidate; fi
if [[ "$mode" == --demo-v12 ]]; then version=12; name=https_controller_v12_demo; fi
sketch="$ROOT/noise_experiments/$name"
out="$ROOT/noise_experiments/${name}_build"
mkdir -p "$sketch" "$out"
rm -rf "$sketch/src" "$out/.arduino-build" # ignored candidate ONLY; no stale duplicate sources
cp -R "$PORT" "$sketch/src"
cp "$ROOT/https_experiment/noise_firmware.ino" "$sketch/$name.ino"
cp "$ROOT/https_experiment/"{NoiseLink.cpp,NoiseLink.h,IdentityStore.cpp,IdentityStore.h} "$ROOT/TrustedPublicKey.h" "$sketch/"
cp "$ROOT/private_keys/noise/generated_public/controller.h" "$sketch/LinkPublicPins.h"
extra=''
if [[ "$mode" == --usb ]]; then
  "$ROOT/https_experiment/prepare_tls_identity.sh"
  cp "$ROOT/https_experiment/TlsBootstrap.cpp" "$sketch/"
  cp "$ROOT/noise_experiments/https_tls_bootstrap/TlsBootstrapPrivate.h" "$sketch/"
  extra=' -DTLS_USB_BOOTSTRAP=1'
else
  [[ ! -e "$sketch/TlsBootstrapPrivate.h" && ! -e "$sketch/BootstrapPrivate.h" ]] || {
    echo 'STOP: private key in OTA build directory' >&2; exit 1;
  }
fi
"$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" compile -b esp32:esp32:esp32 -j 2 \
  --build-property "compiler.c.extra_flags=-DUSE_LIBSODIUM=1 -Dnoise_init=noisec_init -I$sketch/src -I$sketch/src/protocol" \
  --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=0 -DFW_VERSION=$version$extra -Dnoise_init=noisec_init -I$sketch/src" \
  --build-path "$out/.arduino-build" --output-dir "$out" "$sketch"
image="$out/$name.ino.bin"
ROOT="$ROOT" IMAGE="$image" MODE="$mode" "$ROOT/.venv/bin/python" - <<'PY'
from pathlib import Path
import os
root, image = Path(os.environ['ROOT']), Path(os.environ['IMAGE'])
data = image.read_bytes()
mode = os.environ['MODE']
if len(data) > 0x140000: raise SystemExit('STOP: exceeds OTA partition')
for role in ('controller', 'edge1', 'edge2'):
    key = (root / 'private_keys/noise' / f'{role}.x25519').read_bytes()
    if len(key) != 32 or key in data: raise SystemExit('STOP: static identity embedded in OTA binary')
tls_key = root / 'private_keys' / 'host_tls' / 'server.key'
if mode != '--usb' and tls_key.exists() and tls_key.read_bytes() in data:
    raise SystemExit('STOP: actual TLS private key embedded in OTA binary')
if mode == '--usb' and (not tls_key.exists() or tls_key.read_bytes() not in data):
    raise SystemExit('STOP: USB-only image missing expected TLS provisioning key')
if b'POST image with valid Content-Length required' in data:
    raise SystemExit('STOP: legacy plaintext HTTP update linked in')
print(f'LOCAL-ONLY {mode} candidate: {len(data)} / {0x140000} bytes; legacy HTTP POST absent.')
PY
if [[ "$mode" == --ota-v11 || "$mode" == --demo-v12 ]]; then
  "$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" sign \
    --private "$ROOT/private_keys/demo.pem" --image "$image" --role 0 --version "$version"
  "$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
    --public "$ROOT/private_keys/demo_public.bin" --image "$image" \
    --manifest "$image.manifest" --role 0 --current-version "$((version - 1))"
fi
