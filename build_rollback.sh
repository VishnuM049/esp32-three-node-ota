#!/bin/bash
# Build ONLY controller v5 and deliberately failing signed controller v6 test candidate.
# Never flash v6 over USB; it is designed to reject its first OTA boot and roll back.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
CFG="$HOME/.arduinoIDE/arduino-cli.yaml"
[[ -f "$HERE/TrustedPublicKey.h" ]] || { echo 'Missing trusted public key' >&2; exit 1; }
for version in 5 6; do
  flags="-DNODE_ROLE=0 -DFW_VERSION=$version"
  if (( version == 6 )); then flags="$flags -DFORCE_SELF_TEST_FAILURE=1"; fi
  output="$HERE/rollback_firmware/controller_v${version}"
  echo "Compiling controller v$version (forced self-test failure: $(( version == 6 )))..."
  "$CLI" --config-file "$CFG" compile -b esp32:esp32:esp32 -j 2 \
    --build-property "compiler.cpp.extra_flags=$flags" --output-dir "$output" "$HERE" | tail -3
  bin="$output/ota_prototype.ino.bin"
  bytes=$(stat -f '%z' "$bin")
  (( bytes <= 0x140000 )) || { echo "Image exceeds OTA slot: $bytes" >&2; exit 1; }
  "$HERE/.venv/bin/python" "$HERE/host_signing/manifest.py" sign \
    --private "$HERE/private_keys/demo.pem" --image "$bin" --role 0 --version "$version"
  "$HERE/.venv/bin/python" "$HERE/host_signing/manifest.py" verify \
    --public "$HERE/private_keys/demo_public.bin" --image "$bin" \
    --manifest "${bin}.manifest" --role 0 --current-version "$((version - 1))"
done
