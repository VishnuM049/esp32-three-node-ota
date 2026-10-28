#!/bin/bash
# Read-only preflight. No internet, Wi-Fi changes, USB flash, or OTA upload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="$ROOT/.venv/bin/python"
[[ -x "$PY" ]] || { echo 'Missing local Python virtual environment' >&2; exit 1; }
"$PY" -c 'import cryptography' || { echo 'Local Ed25519 dependency unavailable' >&2; exit 1; }
for tool in curl xxd networksetup ipconfig python3; do
  command -v "$tool" >/dev/null || { echo "Missing local command $tool" >&2; exit 1; }
done
for path in private_keys/demo.pem private_keys/demo_public.bin \
            private_keys/noise/controller.x25519 private_keys/noise/edge1.x25519 \
            private_keys/noise/edge2.x25519 web_log/server.py web_log/index.html; do
  [[ -s "$path" ]] || { echo "Missing local dependency $path" >&2; exit 1; }
done
for role in controller edge1 edge2; do
  case "$role" in
    controller) id=0; current=8; next=9;;
    edge1) id=1; current=7; next=8;;
    edge2) id=2; current=7; next=8;;
  esac
  name="${role}_encrypted_v${next}"
  image="noise_experiments/${name}_build/${name}.ino.bin"
  [[ -s "$image" && -s "$image.manifest" ]] || {
    echo "Missing ignored signed ${role} v${next} demo artifacts; do not assume GitHub has them." >&2; exit 1;
  }
  bytes=$(stat -f '%z' "$image")
  (( bytes > 0 && bytes <= 0x140000 )) || { echo "Invalid ${role} OTA slot size" >&2; exit 1; }
  for artifact in "$image" "$image.manifest"; do
    git check-ignore -q "$artifact" || {
      echo "STOP: ${role} private build artifact no longer ignored by Git: $artifact" >&2; exit 1;
    }
  done
  "$PY" host_signing/manifest.py verify --public private_keys/demo_public.bin \
    --image "$image" --manifest "$image.manifest" --role "$id" --current-version "$current"
  "$PY" - "$image" <<'PY'
from pathlib import Path
import sys
image = Path(sys.argv[1]).read_bytes()
for role in ('controller', 'edge1', 'edge2'):
    secret = (Path('private_keys/noise') / f'{role}.x25519').read_bytes()
    if len(secret) != 32 or secret in image:
        raise SystemExit('STOP: embedded private link identity or invalid key file in OTA image')
PY
  echo "READY LOCALLY: $role v$current -> v$next ($bytes bytes; no embedded provisioned static secret)"
done
PYTHONPATH=host_signing "$PY" -m unittest discover -s host_signing -q
python3 -m unittest discover -s web_log -p 'test_*.py' -q
ip=$(ipconfig getifaddr en0 2>/dev/null || true)
if [[ "$ip" == 192.168.4.* ]]; then
  echo "Mac demo-AP IP: $ip; query controller /status separately before any OTA."
else
  echo 'Mac not on demo AP. This is normal for off-site preparation; sender will refuse until connected.'
fi
echo 'OFFLINE PREFLIGHT PASSED. No boards contacted or changed; live hardware status is NOT established by this check.'
