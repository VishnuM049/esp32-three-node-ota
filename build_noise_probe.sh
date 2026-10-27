#!/bin/bash
# Compile-only feasibility experiment: a narrowed Noise-C KK/25519/ChaChaPoly/SHA256
# port with the ESP32 core's libsodium. DOES NOT flash or implement OTA encryption.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM="$ROOT/noise_experiments/noise-c"
SCRATCH="$ROOT/noise_experiments/noise_probe"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
[[ "$(git -C "$UPSTREAM" rev-parse HEAD)" == cfe25410979a87391bb9ac8d4d4bef64e9f268c6 ]] || {
  echo 'Missing/patched upstream Noise-C checkout; refusing build' >&2; exit 1;
}
rm -rf "$SCRATCH" # generated/ignored experiment only; remove stale sources
mkdir -p "$SCRATCH/src/protocol" "$SCRATCH/src/backend/sodium" "$SCRATCH/src/crypto/chacha" "$SCRATCH/src/crypto/sha2" "$SCRATCH/src/noise"
cp -R "$UPSTREAM/include/noise/." "$SCRATCH/src/noise/"
cp "$UPSTREAM/COPYING" "$SCRATCH/NOISE-C-LICENSE"
for name in cipherstate dhstate errors handshakestate hashstate names patterns randstate rand_sodium signstate symmetricstate util; do
  cp "$UPSTREAM/src/protocol/$name.c" "$SCRATCH/src/protocol/$name.c"
done
rm -f "$SCRATCH/src/protocol/internal.c" # scratch may have stale unsupported AES factory
cp "$UPSTREAM/src/protocol/internal.h" "$SCRATCH/src/protocol/internal.h"
# Arduino's dependency resolver only sees same-directory quoted includes.
cp "$UPSTREAM/src/protocol/internal.h" "$SCRATCH/src/backend/sodium/internal.h"
for name in cipher-chachapoly dh-curve25519 hash-sha256 sign-ed25519; do
  cp "$UPSTREAM/src/backend/sodium/$name.c" "$SCRATCH/src/backend/sodium/$name.c"
done
# Header-only copies for Arduino's dependency scanner (conditional includes are
# scanned even when libsodium is enabled). Donna is included by Noise-C's backend.
cp "$UPSTREAM/src/crypto/chacha/chacha.h" "$SCRATCH/src/crypto/chacha/"
cp "$UPSTREAM/src/crypto/sha2/sha256.h" "$SCRATCH/src/crypto/sha2/"
for name in curve25519-donna curve25519-donna-c64; do
  cp "$UPSTREAM/src/crypto/donna/$name.c" "$SCRATCH/src/backend/sodium/$name.h"
done
"$ROOT/.venv/bin/python" - "$SCRATCH/src/backend/sodium/dh-curve25519.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
src = path.read_text()
for name in ("curve25519-donna", "curve25519-donna-c64"):
    old = f'"crypto/donna/{name}.c"'
    if src.count(old) != 1:
        raise RuntimeError(f'Unexpected upstream include: {old}')
    src = src.replace(old, f'"{name}.h"')
path.write_text(src)
PY
# Remove ONLY unused algorithm constructors in this scratch prototype; upstream
# library remains untouched. A release would require review and vectors.
"$ROOT/.venv/bin/python" - "$SCRATCH/src/protocol" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
remove = {
    'dhstate.c': ['CURVE448', 'NEWHOPE'],
    'cipherstate.c': ['AESGCM'],
    'hashstate.c': ['BLAKE2s', 'BLAKE2b', 'SHA512'],
}
for name, algorithms in remove.items():
    file = p / name
    source = file.read_text()
    for algorithm in algorithms:
        import re
        case = re.compile(r'    case NOISE_(?:DH|CIPHER|HASH)_' + re.escape(algorithm) +
                          r':\n        \*state = noise_[a-zA-Z0-9_]+_new\(\);\n        break;\n')
        source, count = case.subn('', source)
        if count != 1:
            raise RuntimeError(f'Unexpected upstream factory for {algorithm}: {count} matches')
    file.write_text(source)
PY
cat > "$SCRATCH/noise_probe.ino" <<'INO'
#include <Arduino.h>
#include <sodium.h>
#include <noise/protocol.h>
void setup() {
  Serial.begin(115200);
  int sodium = sodium_init();
  int init = noise_init();
  NoiseHandshakeState *state = nullptr;
  int kk = noise_handshakestate_new_by_name(&state,
      "Noise_KK_25519_ChaChaPoly_SHA256", NOISE_ROLE_INITIATOR);
  Serial.printf("Noise-C compile probe sodium=%d init=%d KK=%d\n", sodium, init, kk);
  if (state) noise_handshakestate_free(state);
}
void loop() { delay(1000); }
INO
"$CLI" --config-file "$HOME/.arduinoIDE/arduino-cli.yaml" compile -b esp32:esp32:esp32 -j 2 \
  --build-property "compiler.c.extra_flags=-DUSE_LIBSODIUM=1 -Dnoise_init=noisec_init -I$SCRATCH/src -I$SCRATCH/src/protocol" \
  --build-property "compiler.cpp.extra_flags=-Dnoise_init=noisec_init -I$SCRATCH/src" \
  --output-dir "$ROOT/noise_experiments/probe_build" "$SCRATCH"
