#!/bin/bash
# One-shot LIVE DEMO update for the already-proven v8 controller / v7 edges.
# This script never builds, flashes, retries, or alters Wi-Fi configuration.
# Mac->controller HTTP is PLAINTEXT; controller->edge uses authenticated Noise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  edge1) role=1; current=7; version=8; endpoint=edge1;;
  edge2) role=2; current=7; version=8; endpoint=edge2;;
  controller) role=0; current=8; version=9; endpoint=update;;
  *) echo "Usage: $0 edge1|edge2|controller (one-time signed OTA; NO AUTOMATIC RETRY)" >&2; exit 2;;
esac
[[ $# == 1 ]] || { echo 'Exactly one role required' >&2; exit 2; }
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'STOP: Mac not connected to demo AP; no upload sent.' >&2; exit 1;
}
name="${1}_encrypted_v${version}"
image="$ROOT/noise_experiments/${name}_build/$name.ino.bin"
manifest="$image.manifest"
[[ -f "$image" && -f "$manifest" ]] || { echo 'Missing locally signed live-demo image' >&2; exit 1; }
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
data = image.read_bytes()
for role in ('controller', 'edge1', 'edge2'):
    secret = (root / 'private_keys/noise' / f'{role}.x25519').read_bytes()
    if len(secret) != 32 or secret in data:
        raise SystemExit('STOP: provisioned private key in OTA image or invalid key file; NO UPLOAD')
print('OTA image scanned: no provisioned raw X25519 private keys')
PY
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" \
  --manifest "$manifest" --role "$role" --current-version "$current"
status=$(curl --noproxy '*' --connect-timeout 4 --max-time 20 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $status"
[[ "$status" == *'role=0 version=8 noise=1'* && "$status" == *'ota=valid'* ]] || {
  echo 'STOP: controller must be v8 valid with Noise; no upload sent.' >&2; exit 1;
}
# Both peers must be authenticated and already valid. Edge uploads can run in
# either order. The controller upload is LAST to avoid a reboot mid-edge demo.
[[ "$status" =~ edge1_secure=v(7|8)_ota2_ && "$status" =~ edge2_secure=v(7|8)_ota2_ ]] || {
  echo 'STOP: both edges must be authenticated and OTA-valid; no upload sent.' >&2; exit 1;
}
if (( role == 0 )); then
  [[ "$status" == *'edge1_secure=v8_ota2_'* && "$status" == *'edge2_secure=v8_ota2_'* ]] || {
    echo 'STOP: update both edges first; controller demo OTA is last.' >&2; exit 1;
  }
else
  [[ "$status" == *"edge${role}_secure=v${current}_ota2_"* ]] || {
    echo "STOP: target edge${role} already updated or wrong version; NEVER replay." >&2; exit 1;
  }
fi
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'STOP: wrong manifest size' >&2; exit 1; }
echo "ONE-SHOT signed ${1} v${version} OTA; NO RETRIES if anything times out."
response=$(curl --noproxy '*' --connect-timeout 5 --max-time 240 --fail-with-body -sS \
  -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" \
  "http://192.168.4.1/$endpoint") || {
    echo 'STOP: ambiguous upload response. Query status/serial; do NOT resend blindly.' >&2; exit 1;
  }
echo "$response"
if (( role == 0 )); then
  [[ "$response" == *'Signed image accepted; rebooting'* ]] || {
    echo 'STOP: unexpected response; query status and do NOT resend.' >&2; exit 1;
  }
else
  [[ "$response" == *'Authenticated edge accepted signed image; rebooting'* ]] || {
    echo 'STOP: unexpected response; query status and do NOT resend.' >&2; exit 1;
  }
fi
for i in {1..10}; do
  sleep 3
  state=$(curl --noproxy '*' --connect-timeout 3 --max-time 18 --fail-with-body -sS \
    http://192.168.4.1/status 2>/dev/null || :)
  echo "After $i: $state"
  if (( role == 0 )); then
    if [[ "$state" == *'role=0 version=9 noise=1'* && "$state" == *'ota=valid'* ]]; then
      echo 'CONFIRMED controller v9 OTA valid. If edges are unregistered, power-cycle each edge ONCE; do not resend firmware.'
      exit 0
    fi
  else
    if [[ "$state" == *"edge${role}_secure=v${version}_ota2_"* ]]; then
      echo "CONFIRMED edge${role} v${version} OTA valid over authenticated Noise."
      exit 0
    fi
  fi
done
echo 'STOP: no independent valid-boot confirmation. Inspect status/serial; NEVER retry automatically.' >&2
exit 1
