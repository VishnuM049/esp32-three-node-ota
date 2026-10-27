#!/bin/bash
# Build authenticated v5 test candidates for edge1/edge2; the negative probe
# corrupts a copy of each image IN MEMORY before sending. Never send these
# untampered images unless deliberately upgrading to v5 in a later experiment.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
CFG="$HOME/.arduinoIDE/arduino-cli.yaml"
for role in 1 2; do
  output="$HERE/rollback_firmware/edge${role}_v5"
  echo "Compiling secure edge${role} v5 for hash-rejection test..."
  "$CLI" --config-file "$CFG" compile -b esp32:esp32:esp32 -j 2 \
    --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=$role -DFW_VERSION=5" \
    --output-dir "$output" "$HERE" | tail -3
  bin="$output/ota_prototype.ino.bin"
  bytes=$(stat -f '%z' "$bin")
  (( bytes <= 0x140000 )) || { echo "Image exceeds OTA slot: $bytes" >&2; exit 1; }
  "$HERE/.venv/bin/python" "$HERE/host_signing/manifest.py" sign \
    --private "$HERE/private_keys/demo.pem" --image "$bin" --role "$role" --version 5
  "$HERE/.venv/bin/python" "$HERE/host_signing/manifest.py" verify \
    --public "$HERE/private_keys/demo_public.bin" --image "$bin" \
    --manifest "${bin}.manifest" --role "$role" --current-version 4
done
