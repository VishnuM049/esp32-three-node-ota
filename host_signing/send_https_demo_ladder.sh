#!/bin/bash
# Explicit --plan is read-only; --send consumes EXACTLY ONE next role/version.
# No Wi-Fi switch, USB flash, image build, fallback to HTTP, or automatic retry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 && ( "$1" == --plan || "$1" == --send ) &&
   ( "$2" == edge1 || "$2" == edge2 || "$2" == controller ) ]] || {
  echo 'Usage: send_https_demo_ladder.sh --plan|--send edge1|edge2|controller' >&2; exit 2;
}
mode="$1"; target="$2"
[[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] || {
  echo 'STOP: Mac not on OTA-CLASS-DEMO (192.168.4.x); no upload' >&2; exit 1;
}
cert="$ROOT/private_keys/host_tls/server.crt"
[[ -s "$cert" ]] || { echo 'STOP: missing local pinned controller certificate' >&2; exit 1; }
status=$(curl --noproxy '*' --connect-timeout 4 --max-time 35 --fail-with-body -sS http://192.168.4.1/status) || {
  echo 'STOP: status unavailable/slow; no upload. Do not flash to fix status.' >&2; exit 1;
}
echo "Observed: $status"
plan=$("$ROOT/.venv/bin/python" "$ROOT/host_signing/demo_ladder_plan.py" "$target" <<< "$status") || exit 1
IFS=$'\t' read -r role current next name endpoint <<< "$plan"
image="$ROOT/noise_experiments/${name}_build/${name}.ino.bin"
manifest="$image.manifest"
[[ -s "$image" && -s "$manifest" && -s "$ROOT/private_keys/host_tls/server.key" ]] || {
  echo "STOP: missing $target v$next image/manifest or local TLS identity; no upload" >&2; exit 1;
}
for artifact in "$image" "$manifest"; do
  git -C "$ROOT" check-ignore -q "$artifact" || {
    echo "STOP: local image not Git-ignored: $artifact" >&2; exit 1;
  }
done
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" --manifest "$manifest" \
  --role "$role" --current-version "$current"
"$ROOT/.venv/bin/python" - "$ROOT" "$image" <<'PY'
from pathlib import Path
import sys
root, image = map(Path, sys.argv[1:])
body = image.read_bytes()
if not 0 < len(body) <= 0x140000: raise SystemExit('STOP: image exceeds OTA partition')
for role in ('controller', 'edge1', 'edge2'):
    key = (root / 'private_keys/noise' / f'{role}.x25519').read_bytes()
    if len(key) != 32 or key in body: raise SystemExit('STOP: private Noise identity in OTA image')
tls = (root / 'private_keys/host_tls/server.key').read_bytes()
if tls in body: raise SystemExit('STOP: TLS private key in OTA image')
print('Verified image size and absence of provisioned private-key bytes')
PY
code=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 4 --max-time 15 \
  -sS -o /dev/null -w '%{http_code}' https://192.168.4.1/no-upload) || {
  echo 'STOP: certificate-verified HTTPS handshake failed; no upload' >&2; exit 1;
}
[[ "$code" == 404 ]] || { echo "STOP: unexpected HTTPS probe HTTP $code" >&2; exit 1; }
echo "NEXT: $target v$current -> v$next over verified HTTPS; local image: $image"
if [[ "$mode" == --plan ]]; then
  echo 'PLAN ONLY: no firmware sent; installed version unchanged.'
  exit 0
fi
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'STOP: manifest length incorrect' >&2; exit 1; }
read -r -p "Type 'SEND $target v$next' to consume this version ONCE: " answer
[[ "$answer" == "SEND $target v$next" ]] || { echo 'Cancelled; no upload.'; exit 1; }
log_result() {
  python3 "$ROOT/web_log/record_event.py" "$target" "$next" "$1" ||
    echo 'Warning: Mac-local browser event file unavailable; OTA independent' >&2
}
echo 'Sending one signed image. Never blindly resend on timeout or Wi-Fi roam.'
log_result started
response=$(curl --noproxy '*' --cacert "$cert" --connect-timeout 5 --max-time 240 \
  --fail-with-body -sS -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" "https://192.168.4.1/$endpoint") || {
  log_result ambiguous
  echo 'STOP: ambiguous HTTPS response. Inspect status/serial; NEVER auto-retry.' >&2; exit 1;
}
echo "$response"
if [[ "$target" == controller ]]; then expected='Signed image accepted; rebooting';
else expected='Authenticated edge accepted signed image; rebooting'; fi
[[ "$response" == *"$expected"* ]] || {
  log_result ambiguous
  echo 'STOP: unexpected response. Check status, never assume failure or resend.' >&2; exit 1;
}
log_result accepted
if [[ "$target" != controller ]]; then
  echo 'Quiet first-boot window: do not run the Mac browser poller for 45 seconds.'
  sleep 45
fi
for i in {1..11}; do
  sleep 5
  if [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" != 192.168.4.* ]]; then
    log_result ambiguous
    echo 'STOP: Mac left demo AP during boot. Rejoin and GET /status; never resend.' >&2; exit 1
  fi
  after=$(curl --noproxy '*' --connect-timeout 3 --max-time 35 --fail-with-body -sS \
    http://192.168.4.1/status 2>/dev/null || :)
  echo "After $i: $after"
  if [[ "$target" == controller ]]; then
    if [[ "$after" == *"role=0 version=$next noise=1 tls=1"* && "$after" == *'ota=valid'* &&
          "$after" =~ edge1_secure=v(9|10|11|12)_ota2_ &&
          "$after" =~ edge2_secure=v(9|10|11|12)_ota2_ ]]; then
      log_result confirmed
      echo "CONFIRMED controller v$next valid; both edges authenticated/valid."
      exit 0
    fi
  elif [[ "$after" == *"${target}_secure=v${next}_ota2_"* &&
          "$after" =~ edge1_secure=v(9|10|11|12)_ota2_ &&
          "$after" =~ edge2_secure=v(9|10|11|12)_ota2_ &&
          "$after" == *"role=0 version="* && "$after" == *'ota=valid'* ]]; then
    log_result confirmed
    echo "CONFIRMED $target v$next valid via HTTPS + pinned Noise."
    exit 0
  fi
done
log_result ambiguous
echo 'STOP: valid boot not confirmed. Inspect status/serial; NEVER automatically retry.' >&2
exit 1
