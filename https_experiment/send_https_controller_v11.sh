#!/bin/bash
# One-shot signed controller v10 -> v11 OTA over verified HTTPS. No Wi-Fi changes/retries.
set -euo pipefail
[[ $# == 0 ]] || { echo 'Usage: send_https_controller_v11.sh (one use)' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'STOP: Mac is not on demo AP' >&2; exit 1;
}
cert="$ROOT/private_keys/host_tls/server.crt"
image="$ROOT/noise_experiments/https_controller_v11_candidate_build/https_controller_v11_candidate.ino.bin"
manifest="$image.manifest"
[[ -s "$cert" && -s "$image" && -s "$manifest" ]] || {
  echo 'STOP: missing local pinned cert/image/manifest' >&2; exit 1;
}
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" --manifest "$manifest" \
  --role 0 --current-version 10
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
body = image.read_bytes()
for role in ('controller','edge1','edge2'):
    secret = (root/'private_keys/noise'/f'{role}.x25519').read_bytes()
    if len(secret) != 32 or secret in body:
        raise SystemExit('STOP: embedded static Noise key in OTA image')
tls = (root/'private_keys/host_tls/server.key').read_bytes()
if tls in body: raise SystemExit('STOP: embedded TLS private key in OTA image')
if len(body) > 0x140000: raise SystemExit('STOP: OTA slot exceeded')
PY
state=$(curl --noproxy '*' --connect-timeout 4 --max-time 22 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $state"
[[ "$state" == *'role=0 version=10 noise=1 tls=1'* &&
   "$state" == *'edge1_secure=v9_ota2_'* && "$state" == *'edge2_secure=v9_ota2_'* ]] || {
  echo 'STOP: expected controller v10 TLS + both authenticated/valid edge v9; no upload' >&2; exit 1;
}
code=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 4 --max-time 15 \
  -sS -o /dev/null -w '%{http_code}' https://192.168.4.1/no-upload) || {
  echo 'STOP: TLS controller authentication failed' >&2; exit 1;
}
[[ "$code" == 404 ]] || { echo "STOP: unexpected TLS probe HTTP $code" >&2; exit 1; }
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || exit 1
read -r -p "Type 'CONSUME controller v11' to send ONCE: " answer
[[ "$answer" == 'CONSUME controller v11' ]] || { echo 'Cancelled; no upload'; exit 1; }
response=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 5 --max-time 240 \
  --fail-with-body -sS -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" https://192.168.4.1/update) || {
  echo 'STOP: ambiguous controller result. Check status/serial; NEVER blindly resend.' >&2; exit 1;
}
echo "$response"
[[ "$response" == *'Signed image accepted; rebooting'* ]] || {
  echo 'STOP: unexpected result. Check status; NEVER resend blindly.' >&2; exit 1;
}
echo 'Transfer accepted; this is NOT boot confirmation. Rejoin AP and independently check controller v11 ota=valid and both edges.'
