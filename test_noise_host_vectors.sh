#!/bin/bash
# Native host sanity check of the same narrowed Noise-C port compiled for ESP32.
# Uses upstream KK vectors; DOES NOT prove on-device interoperability.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="$ROOT/noise_experiments/noise_probe/src"
UPSTREAM="$ROOT/noise_experiments/noise-c"
OUT="$ROOT/noise_experiments/host_vectors"
[[ -f "$PORT/protocol/handshakestate.c" ]] || { echo 'Run ./build_noise_probe.sh first' >&2; exit 1; }
mkdir -p "$OUT"
"$ROOT/.venv/bin/python" - "$UPSTREAM/tests/vector" "$OUT" <<'PY'
import json
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:])
for filename in ('noise-c-basic.txt', 'cacophony.txt'):
    records = json.loads((source / filename).read_text())['vectors']
    matches = [v for v in records if v.get('name') == 'Noise_KK_25519_ChaChaPoly_SHA256']
    if len(matches) != 1 or len(matches[0]['messages']) != 6:
        raise ValueError(f'Expected one full KK vector from {filename}')
    (target / filename).write_text(json.dumps({'vectors': matches}))
PY
mapfile=()
while IFS= read -r -d '' source; do mapfile+=("$source"); done < <(find "$PORT" -name '*.c' -print0)
clang -O2 -DUSE_LIBSODIUM=1 -Dnoise_init=noisec_init \
  -I"$PORT" -I"$PORT/protocol" -I/opt/homebrew/include \
  "${mapfile[@]}" "$UPSTREAM/tests/vector/test-vector.c" \
  "$UPSTREAM/tests/vector/json-reader.c" -L/opt/homebrew/lib -lsodium \
  -o "$OUT/test-vector"
"$OUT/test-vector" "$OUT/noise-c-basic.txt" "$OUT/cacophony.txt"
