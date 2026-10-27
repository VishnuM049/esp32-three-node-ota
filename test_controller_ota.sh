#!/bin/bash
# Run with your Mac joined to Wi-Fi 'OTA-CLASS-DEMO'.
# The initial upload goes over Wi-Fi; USB is only supplying power/serial.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE=http://192.168.4.1
COMMON=(curl --noproxy '*' --connect-timeout 3 --fail-with-body -sS)
status() { "${COMMON[@]}" --max-time 5 "$BASE/status"; }

echo 'Checking controller before update...'
initial=$(status)
echo "$initial"
if [[ "$initial" == *'role=0 version=2'* ]]; then
  echo 'PASS: Controller is already running v2. No firmware sent.'
  exit 0
fi
if [[ "$initial" != *'role=0 version=1'* ]]; then
  echo 'Unexpected controller version; refusing to upload.' >&2
  exit 1
fi

echo 'Sending controller v2 over Wi-Fi (do NOT press Upload in Arduino IDE)...'
"${COMMON[@]}" --max-time 120 -H 'Content-Type: application/octet-stream' -H 'Expect:' \
  --data-binary "@$HERE/firmware/controller_v2/ota_prototype.ino.bin" "$BASE/update"
echo 'Waiting for reboot...'
sleep 5
warned=0
for i in {1..45}; do
  current_ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  if [[ "$current_ip" != 192.168.4.* ]]; then
    if (( warned == 0 )); then
      echo 'Mac left the ESP32 Wi-Fi during reboot. Rejoin OTA-CLASS-DEMO to confirm v2.'
      warned=1
    fi
  elif result=$(status 2>/dev/null); then
    echo "$result"
    if [[ "$result" == *'role=0 version=2'* ]]; then
      echo 'PASS: Controller updated from v1 to v2 over Wi-Fi.'
      exit 0
    fi
  fi
  sleep 2
done
echo 'Update was accepted, but this Mac could not confirm the version. This is NOT proof that OTA failed.' >&2
echo "Rejoin OTA-CLASS-DEMO, then run: curl --noproxy '*' --max-time 5 $BASE/status" >&2
exit 2
