#!/bin/bash
# Controller-only rollback experiment. 5: healthy OTA from v4. 6: intentionally failing OTA from v5.
# NEVER USB-flash v6. Connect Mac to OTA-CLASS-DEMO; keep board powered during upload.
set -euo pipefail
case "${1:-}" in
  5) current=4;;
  6) current=5;;
  *) echo "Usage: $0 5|6 (run 5 first and confirm v5 before 6)" >&2; exit 2;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
image="$ROOT/rollback_firmware/controller_v${1}/ota_prototype.ino.bin"
manifest="$image.manifest"
[[ -f "$image" && -f "$manifest" ]] || { echo 'Missing built/signed rollback image' >&2; exit 1; }
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --public "$ROOT/private_keys/demo_public.bin" --image "$image" \
  --manifest "$manifest" --role 0 --current-version "$current"
state=$(curl --noproxy '*' --connect-timeout 3 --max-time 5 --fail-with-body -sS http://192.168.4.1/status)
echo "Before: $state"
[[ "$state" == *"role=0 version=$current"* ]] || { echo 'Unexpected controller version; refusing update.' >&2; exit 1; }
if [[ "$1" == 6 ]]; then
  echo 'IMPORTANT: v6 is deliberately signed but fails its first-boot self-test.'
  echo 'Expected result is rollback to v5; losing contact is NOT proof of success.'
  read -r -p 'Type ROLLBACK to send the intentionally failing OTA test: ' answer
  [[ "$answer" == ROLLBACK ]] || exit 1
fi
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'Malformed manifest hex' >&2; exit 1; }
curl --noproxy '*' --connect-timeout 5 --max-time 120 --fail-with-body \
  -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" http://192.168.4.1/update
echo 'Do not retry. After reboot, rejoin OTA-CLASS-DEMO if needed and check /status.'
if [[ "$1" == 6 ]]; then echo 'EXPECTED /status: role=0 version=5 (previous working app).'; fi
