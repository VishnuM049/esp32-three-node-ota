#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI='/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'
CFG="$HOME/.arduinoIDE/arduino-cli.yaml"
for role in 0 1 2; do
  case "$role" in
    0) node=controller;;
    1) node=edge1;;
    2) node=edge2;;
  esac
  for version in 1 2; do
    name="${node}_v${version}"
    echo "Building $name"
    "$CLI" --config-file "$CFG" compile -b esp32:esp32:esp32 -j 2 \
      --build-property "compiler.cpp.extra_flags=-DNODE_ROLE=$role -DFW_VERSION=$version" \
      --output-dir "$HERE/firmware/$name" "$HERE" | tail -3
  done
done
printf '\nImages:\n'
find "$HERE/firmware" -name 'ota_prototype.ino.bin' -exec ls -lh {} \;
