#!/bin/bash
# Run this AFTER joining the Mac to Wi-Fi 'OTA-CLASS-DEMO'.
# No USB firmware upload: image goes over Wi-Fi to 192.168.4.1.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE=http://192.168.4.1
CURL=(curl --noproxy '*' --connect-timeout 5 --max-time 120 --fail-with-body -sS)
echo 'Checking controller before update...'
"${CURL[@]}" "$BASE/status"
echo 'Sending controller v2 over Wi-Fi (do NOT press Upload in Arduino IDE)...'
"${CURL[@]}" -H 'Content-Type: application/octet-stream' -H 'Expect:' \
  --data-binary "@$HERE/firmware/controller_v2/ota_prototype.ino.bin" "$BASE/update"
echo 'Waiting for reboot...'
sleep 5
for i in {1..12}; do
  if status=$("${CURL[@]}" "$BASE/status" 2>/dev/null); then
    echo "$status"
    if [[ "$status" == *'role=0 version=2'* ]]; then
      echo 'PASS: Controller updated from v1 to v2 over Wi-Fi.'
      exit 0
    fi
  fi
  sleep 2
done
echo 'No v2 confirmation. Check board power and serial output.' >&2
exit 1
