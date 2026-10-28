#!/bin/bash
# One-shot, non-retrying v8->v9 edge reconnection candidate over verified HTTPS.
# Requires controller v10 with NVS TLS identity + both edges already v8 valid.
# Does not change Wi-Fi. Explicit user confirmation required before network POST.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  edge1) id=1;;
  edge2) id=2;;
  *) echo 'Usage: send_reconnect_https.sh edge1|edge2' >&2; exit 2;;
esac
[[ $# == 1 ]] || exit 2
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'STOP: Mac not on demo AP; no upload' >&2; exit 1;
}
cert="$ROOT/private_keys/host_tls/server.crt"
[[ -s "$cert" ]] || { echo 'Missing pinned controller TLS certificate' >&2; exit 1; }
name="${1}_reconnect_v9"
image="$ROOT/noise_experiments/${name}_build/${name}.ino.bin"
manifest="$image.manifest"
[[ -s "$image" && -s "$manifest" ]] || { echo 'Missing local signed v9 candidate' >&2; exit 1; }
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" --manifest "$manifest" \
  --role "$id" --current-version 8
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
body = image.read_bytes()
for role in ('controller','edge1','edge2'):
    private = (root/'private_keys/noise'/f'{role}.x25519').read_bytes()
    if len(private)!=32 or private in body: raise SystemExit('STOP: key-bearing OTA binary')
PY
status=$(curl --noproxy '*' --connect-timeout 4 --max-time 22 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $status"
[[ "$status" == *'role=0 version=10 noise=1 tls=1'* &&
   "$status" == *"${1}_secure=v8_ota2_"* &&
   "$status" =~ edge1_secure=v(8|9)_ota2_ && "$status" =~ edge2_secure=v(8|9)_ota2_ ]] || {
  echo 'STOP: v10 HTTPS controller and both authenticated OTA-valid edges required; target must be v8' >&2; exit 1;
}
code=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 4 --max-time 14 \
  -sS -o /dev/null -w '%{http_code}' https://192.168.4.1/no-upload) || {
    echo 'STOP: controller TLS authentication failed' >&2; exit 1;
  }
[[ "$code" == 404 ]] || { echo "Unexpected TLS response $code" >&2; exit 1; }
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || exit 1
echo "WARNING: sending ${1} v9 once makes its prepared v8 permanently old."
read -r -p "Type 'CONSUME ${1} v9' to continue: " answer
[[ "$answer" == "CONSUME ${1} v9" ]] || { echo 'Cancelled; no upload'; exit 1; }
response=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 5 --max-time 240 \
  --fail-with-body -sS -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" "https://192.168.4.1/$1") || {
  echo 'STOP: upload result ambiguous; check status/serial. NEVER blindly retry.' >&2; exit 1;
}
echo "$response"
[[ "$response" == *'Authenticated edge accepted signed image; rebooting'* ]] || {
  echo 'STOP: unexpected response; check status before any retry.' >&2; exit 1;
}
for i in {1..12}; do
  sleep 3
  after=$(curl --noproxy '*' --connect-timeout 3 --max-time 20 --fail-with-body -sS \
    http://192.168.4.1/status 2>/dev/null || :)
  echo "After $i: $after"
  if [[ "$after" == *"${1}_secure=v9_ota2_"* ]]; then
    echo "CONFIRMED ${1} v9 valid over verified HTTPS + pinned Noise."
    exit 0
  fi
done
echo 'STOP: no confirmed valid first boot; inspect status/serial. No retry.' >&2
exit 1
