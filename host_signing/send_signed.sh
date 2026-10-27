#!/bin/bash
# Send a signed v4 image through the controller after all three boards have secure v3 installed.
# Usage: ./host_signing/send_signed.sh controller|edge1|edge2
# Run ONLY while connected to OTA-CLASS-DEMO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  controller) role=0; path=update;;
  edge1) role=1; path=edge1;;
  edge2) role=2; path=edge2;;
  *) echo "Usage: $0 controller|edge1|edge2" >&2; exit 2;;
esac
image="$ROOT/secure_firmware/${1}_v4/ota_prototype.ino.bin"
manifest="${image}.manifest"
[[ -f "$image" && -f "$manifest" ]] || { echo 'Missing signed v4 image or manifest.' >&2; exit 1; }
"$ROOT/.venv/bin/python" "$ROOT/host_signing/manifest.py" verify \
  --image "$image" --manifest "$manifest" --role "$role" --current-version 3
hex=$(xxd -p -c 256 "$manifest" | tr -d '\n')
[[ ${#hex} == 218 ]] || { echo 'Invalid manifest hex length' >&2; exit 1; }
curl_options=(curl --noproxy '*' --connect-timeout 5 --max-time 8 --fail-with-body -sS)
controller=$("${curl_options[@]}" http://192.168.4.1/status)
if (( role == 0 )); then
  status=$controller
else
  ip=$(sed -n "s/.*edge${role}=\([0-9.]*\).*/\1/p" <<< "$controller")
  [[ -n "$ip" && "$ip" != 0.0.0.0 ]] || { echo "Edge $role not registered: $controller" >&2; exit 1; }
  status=$("${curl_options[@]}" "http://${ip}:8080/status")
fi
echo "Current node: $status"
[[ "$status" == *"role=$role version=3"* ]] || { echo 'Target is not secure v3. NOT sending an update.' >&2; exit 1; }
echo "Sending signed ${1} v4. Do not retry automatically if the Mac changes Wi-Fi."
curl --noproxy '*' --connect-timeout 5 --max-time 120 --fail-with-body \
  -H 'Expect:' -H 'Content-Type: application/octet-stream' \
  -H "X-OTA-Manifest: $hex" --data-binary "@$image" "http://192.168.4.1/$path"
echo 'Wait for reboot, then check controller status and target status manually. Do not resend.'
