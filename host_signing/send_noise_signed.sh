#!/bin/bash
# ONE signed OTA update for a USB-bootstrapped, authenticated-Noise star.
# Mac must be on OTA-CLASS-DEMO. Images contain X25519 device PRIVATE KEYS;
# never share/upload them outside the trusted demo network or commit them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  controller) role=0; version=8; current=7; path=update;;
  edge1) role=1; version=7; current=6; path=edge1;;
  edge2) role=2; version=7; current=6; path=edge2;;
  *) echo "Usage: $0 controller|edge1|edge2" >&2; exit 2;;
esac
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'Mac not on demo AP; NO upload sent.' >&2; exit 1;
}
name="${1}_encrypted_v${version}"
image="$ROOT/noise_experiments/${name}_build/$name.ino.bin"
manifest="$image.manifest"
[[ -f "$image" && -f "$manifest" ]] || { echo 'Missing locally built, signed image' >&2; exit 1; }
# A plain Mac->controller upload of a key-bearing image would compromise Noise.
# Always scan the actual candidate binary before ANY network preflight/upload.
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
data = image.read_bytes()
for role in ('controller', 'edge1', 'edge2'):
    secret = (root / 'private_keys/noise' / f'{role}.x25519').read_bytes()
    if len(secret) != 32 or secret in data:
        raise SystemExit('STOP: private identity detected in OTA image or bad key file; NO UPLOAD')
print('Checked actual OTA image: no provisioned X25519 private key bytes present')
PY
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" \
  --manifest "$manifest" --role "$role" --current-version "$current"
status=$(curl --noproxy '*' --connect-timeout 4 --max-time 20 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $status"
[[ "$status" == *"role=0 version=7 noise=1"* ]] || { echo 'Not encrypted controller v7; NO upload.' >&2; exit 1; }
if (( role != 0 )); then
  [[ "$status" == *"edge${role}_secure=v${current}_ota"* ]] || {
    echo "Target edge${role} not authenticated/reachable at v${current}; NO upload." >&2; exit 1;
  }
fi
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'Wrong signed manifest size' >&2; exit 1; }
echo "Sending signed ${1} v${version} ONCE. Do NOT retry on Wi-Fi roam or timeout."
curl --noproxy '*' --connect-timeout 5 --max-time 240 --fail-with-body \
  -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" "http://192.168.4.1/$path"
echo 'Independently check controller /status after reboot/re-registration. No automatic resend.'
