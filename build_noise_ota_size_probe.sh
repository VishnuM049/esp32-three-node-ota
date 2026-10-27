#!/bin/bash
# COMPILE ONLY: estimate Noise-C size in actual signed-OTA sketch. NOT encrypted OTA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE="$ROOT/noise_experiments/noise_probe/src"
SCRATCH="$ROOT/noise_experiments/ota_size_probe"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
[[ -f "$BASE/protocol/handshakestate.c" ]] || { echo 'Run ./build_noise_probe.sh first' >&2; exit 1; }
rm -rf "$SCRATCH" # ignored generated sketch, no keys
mkdir -p "$SCRATCH"
cp -R "$BASE" "$SCRATCH/src"
cp "$ROOT/TrustedPublicKey.h" "$SCRATCH/"
"$ROOT/.venv/bin/python" - "$ROOT/ota_prototype.ino" "$SCRATCH/ota_size_probe.ino" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = '#include <sodium.h>\n'
assert source.count(old) == 1
source = source.replace(old, old + '#include <noise/protocol.h>\n')
old = '  cryptoReady = sodium_init() >= 0;\n'
assert source.count(old) == 1
source = source.replace(old, old + '''  // COMPILE-ONLY SIZE PROBE. This does NOT protect ANY network traffic.
  NoiseHandshakeState *sizeProbe = nullptr;
  int noiseProbeStatus = noise_handshakestate_new_by_name(&sizeProbe,
      "Noise_KK_25519_ChaChaPoly_SHA256", NOISE_ROLE_INITIATOR);
  Serial.printf("Noise KK factory compile probe: %d\\n", noiseProbeStatus);
  if (sizeProbe) noise_handshakestate_free(sizeProbe);
''')
Path(sys.argv[2]).write_text(source)
PY
"$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" compile -b esp32:esp32:esp32 -j 2 \
  --build-property "compiler.c.extra_flags=-DUSE_LIBSODIUM=1 -Dnoise_init=noisec_init -I$SCRATCH/src -I$SCRATCH/src/protocol" \
  --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=0 -DFW_VERSION=7 -Dnoise_init=noisec_init -I$SCRATCH/src" \
  --output-dir "$ROOT/noise_experiments/ota_probe_build" "$SCRATCH"
bytes=$(stat -f '%z' "$ROOT/noise_experiments/ota_probe_build/ota_size_probe.ino.bin")
echo "Controller v7 SIZE PROBE ONLY: $bytes bytes (OTA slot limit: $((0x140000)) bytes)"
(( bytes <= 0x140000 )) || { echo 'FAIL: exceeds OTA slot' >&2; exit 1; }
