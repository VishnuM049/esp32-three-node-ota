#!/bin/bash
# Experimental one-shot sender. --check is read-only; --send CONSUMES the prepared edge v8.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT="$ROOT/private_keys/host_tls/server.crt"
[[ -s "$CERT" ]] || { echo 'Missing local pinned TLS certificate' >&2; exit 1; }
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'STOP: not on demo AP; no upload sent' >&2; exit 1;
}
status=$(curl --noproxy '*' --connect-timeout 4 --max-time 20 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $status"
[[ "$status" == *'role=0 version=10 noise=1 tls=1'* ]] || {
  echo 'STOP: not the candidate HTTPS controller v10; no upload' >&2; exit 1;
}
code=$(curl --noproxy '*' --cacert "$CERT" --connect-timeout 4 --max-time 12 \
  -sS -o /dev/null -w '%{http_code}' https://192.168.4.1/no-upload) || {
  echo 'STOP: TLS certificate verification or handshake failed; no upload' >&2; exit 1;
}
[[ "$code" == 404 ]] || { echo "STOP: unexpected TLS probe response $code; no upload" >&2; exit 1; }
if [[ "${1:---check}" == --check && $# -le 1 ]]; then
  echo 'Verified pinned controller certificate and TLS listener; NO image sent.'
  exit 0
fi
[[ $# == 2 && "$1" == --send && ( "$2" == edge1 || "$2" == edge2 ) ]] || {
  echo 'Usage: send_https_edge.sh --check | --send edge1|edge2 (ONE USE)' >&2; exit 2;
}
role="${2#edge}"; image="$ROOT/noise_experiments/${2}_encrypted_v8_build/${2}_encrypted_v8.ino.bin"
manifest="$image.manifest"
[[ "$status" == *"${2}_secure=v7_ota2_"* && "$status" =~ edge1_secure=v(7|8|9)_ota2_ &&
   "$status" =~ edge2_secure=v(7|8|9)_ota2_ ]] || {
  echo 'STOP: target must be v7; both edges must be authenticated and valid; no upload' >&2; exit 1;
}
[[ -s "$image" && -s "$manifest" ]] || { echo 'Missing prepared one-shot edge image' >&2; exit 1; }
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" --manifest "$manifest" \
  --role "$role" --current-version 7
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
data = image.read_bytes()
for role in ('controller', 'edge1', 'edge2'):
    key = (root/'private_keys/noise'/f'{role}.x25519').read_bytes()
    if len(key) != 32 or key in data:
        raise SystemExit('STOP: private key in OTA image or invalid key file')
PY
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'STOP: bad manifest length' >&2; exit 1; }
echo "WARNING: this will CONSUME ${2} v8, making it unavailable for the original v8-controller demo."
read -r -p "Type 'CONSUME ${2} v8' to proceed: " answer
[[ "$answer" == "CONSUME ${2} v8" ]] || { echo 'Cancelled; no upload.'; exit 1; }
echo 'Sending ONCE with verified HTTPS; never blindly retry an ambiguous result.'
response=$(curl --noproxy '*' --cacert "$CERT" --connect-timeout 5 --max-time 240 \
  --fail-with-body -sS -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" "https://192.168.4.1/$2") || {
  echo 'STOP: ambiguous outcome. Query /status; NEVER blindly retry.' >&2; exit 1;
}
echo "$response"
[[ "$response" == *'Authenticated edge accepted signed image; rebooting'* ]] || {
  echo 'Unexpected reply; inspect status; NEVER blindly retry.' >&2; exit 1;
}
# A first-boot edge has 30 seconds to authenticate its controller. Don't
# starve the controller's single loop with /status queries during that window.
echo 'Waiting 20s without status polling for edge first-boot registration.'
sleep 20
for i in {1..10}; do
  sleep 4
  after=$(curl --noproxy '*' --connect-timeout 3 --max-time 18 --fail-with-body -sS \
    http://192.168.4.1/status 2>/dev/null || :)
  echo "After $i: $after"
  if [[ "$after" == *"${2}_secure=v8_ota2_"* ]]; then
    echo "CONFIRMED ${2} v8 valid after HTTPS -> Noise OTA."
    exit 0
  fi
done
echo 'STOP: no confirmed healthy boot. Do not retry; diagnose status/serial.' >&2
exit 1
