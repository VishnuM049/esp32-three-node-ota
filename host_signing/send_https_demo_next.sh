#!/bin/bash
# ONE-SHOT signed HTTPS -> Noise demo. NEVER builds, changes Wi-Fi, retries, or USB-flashes.
# Installed baseline: controller v11 valid, edge1 + edge2 v9 valid/authenticated.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  edge1) role=1; current=9; next=10; name=edge1_reconnect_v10_demo; endpoint=edge1;;
  edge2) role=2; current=9; next=10; name=edge2_reconnect_v10_demo; endpoint=edge2;;
  controller) role=0; current=11; next=12; name=https_controller_v12_demo; endpoint=update;;
  *) echo 'Usage: send_https_demo_next.sh edge1|edge2|controller (NO AUTO RETRY)' >&2; exit 2;;
esac
[[ $# == 1 ]] || exit 2
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'STOP: Mac not on demo AP; NO upload' >&2; exit 1;
}
image="$ROOT/noise_experiments/${name}_build/${name}.ino.bin"
manifest="$image.manifest"
cert="$ROOT/private_keys/host_tls/server.crt"
tlskey="$ROOT/private_keys/host_tls/server.key"
[[ -s "$image" && -s "$manifest" && -s "$cert" && -s "$tlskey" ]] || {
  echo 'STOP: missing local artifact or TLS identity; NO upload' >&2; exit 1;
}
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" --manifest "$manifest" \
  --role "$role" --current-version "$current"
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
body = image.read_bytes()
if not 0 < len(body) <= 0x140000: raise SystemExit('STOP: OTA slot exceeded')
for role in ('controller', 'edge1', 'edge2'):
    key = (root/'private_keys/noise'/f'{role}.x25519').read_bytes()
    if len(key) != 32 or key in body: raise SystemExit('STOP: private Noise identity in OTA image')
tls = (root/'private_keys/host_tls/server.key').read_bytes()
if tls in body: raise SystemExit('STOP: TLS private key in OTA image')
print('Image fits OTA slot and contains no known provisioned raw private keys')
PY
state=$(curl --noproxy '*' --connect-timeout 4 --max-time 24 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $state"
[[ "$state" == *'role=0 version=11 noise=1 tls=1'* && "$state" == *'ota=valid'* &&
   "$state" =~ edge1_secure=v(9|10)_ota2_ && "$state" =~ edge2_secure=v(9|10)_ota2_ ]] || {
  echo 'STOP: HTTPS controller v11 valid + both authenticated, valid edges v9/v10 required; NO upload' >&2; exit 1;
}
if (( role == 0 )); then
  [[ "$state" == *'edge1_secure=v10_ota2_'* && "$state" == *'edge2_secure=v10_ota2_'* ]] || {
    echo 'STOP: update both edges first; controller v12 LAST' >&2; exit 1;
  }
else
  [[ "$state" == *"edge${role}_secure=v9_ota2_"* ]] || {
    echo "STOP: edge${role} already updated or unexpected version; NEVER replay" >&2; exit 1;
  }
fi
code=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 4 --max-time 15 \
  -sS -o /dev/null -w '%{http_code}' https://192.168.4.1/no-upload) || {
  echo 'STOP: certificate verification/HTTPS handshake failed; NO upload' >&2; exit 1;
}
[[ "$code" == 404 ]] || { echo "STOP: unexpected TLS probe HTTP $code" >&2; exit 1; }
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'STOP: manifest size wrong' >&2; exit 1; }
log_result() {
  python3 "$ROOT/web_log/record_event.py" "$1" "$next" "$2" ||
    echo 'Warning: local event file unavailable; OTA result is independent' >&2
}
echo "ONE upload of signed ${1} v${next} over VERIFIED HTTPS; no automatic retry."
echo 'For highest reliability, leave the Mac browser-log server stopped until the edge confirms its first boot.'
log_result "$1" started
response=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 5 --max-time 240 \
  --fail-with-body -sS -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" "https://192.168.4.1/$endpoint") || {
  log_result "$1" ambiguous
  echo 'STOP: ambiguous response; check status/serial before ANY further action. Never blindly resend.' >&2; exit 1;
}
echo "$response"
if (( role == 0 )); then expected='Signed image accepted; rebooting';
else expected='Authenticated edge accepted signed image; rebooting'; fi
[[ "$response" == *"$expected"* ]] || {
  log_result "$1" ambiguous
  echo 'STOP: unexpected reply; inspect actual status before any action' >&2; exit 1;
}
log_result "$1" accepted
if (( role != 0 )); then
  echo 'Giving first-boot authenticated registration a quiet 45 seconds.'
  sleep 45
fi
for i in {1..11}; do
  sleep 5
  after=$(curl --noproxy '*' --connect-timeout 3 --max-time 20 --fail-with-body -sS \
    http://192.168.4.1/status 2>/dev/null || :)
  echo "After $i: $after"
  if (( role == 0 )); then
    if [[ "$after" == *'role=0 version=12 noise=1 tls=1'* && "$after" == *'ota=valid'* ]]; then
      log_result "$1" confirmed
      echo 'CONFIRMED controller v12 valid. Check both edges re-registered; do not resend firmware.'
      exit 0
    fi
  elif [[ "$after" == *"edge${role}_secure=v10_ota2_"* ]]; then
    log_result "$1" confirmed
    echo "CONFIRMED edge${role} v10 valid via verified HTTPS + authenticated Noise."
    exit 0
  fi
done
log_result "$1" ambiguous
echo 'STOP: valid new boot not independently observed. Check status/serial; never retry automatically.' >&2
exit 1
