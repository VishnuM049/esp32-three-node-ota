#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
CFG="$HOME/.arduinoIDE/arduino-cli.yaml"
[[ -f "$HERE/TrustedPublicKey.h" ]] || { echo 'Missing public key header. Run host_signing/manifest.py keygen first.' >&2; exit 1; }
for role in 0 1 2; do
  case "$role" in 0) node=controller;; 1) node=edge1;; 2) node=edge2;; esac
  for version in 3 4; do
    out="$HERE/secure_firmware/${node}_v${version}"
    echo "Compiling SIGNED OTA $node v$version..."
    "$CLI" --config-file "$CFG" compile -b esp32:esp32:esp32 -j 2 \
      --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=$role -DFW_VERSION=$version" \
      --output-dir "$out" "$HERE" | tail -3
    image="$out/ota_prototype.ino.bin"
    bytes=$(stat -f '%z' "$image")
    if (( bytes > 0x140000 )); then echo "Image $image exceeds OTA slot!" >&2; exit 1; fi
    echo "Image size: $bytes bytes (max 1310720)"
  done
done
