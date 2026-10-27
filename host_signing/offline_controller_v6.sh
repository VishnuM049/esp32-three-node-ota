#!/bin/bash
# DESTRUCTIVE TEST: deliberately failing signed-v6 OTA. May require USB recovery.
# Requires confirmed controller v5 ota=valid; sends v6 once, then restores Wi-Fi.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
normal_ssid="${1:-}"
if [[ -z "$normal_ssid" || "$normal_ssid" == "OTA-CLASS-DEMO" ]]; then
  echo "Usage: $0 'YOUR_USUAL_WIFI_NAME' (SSID only; do NOT enter password)" >&2
  exit 2
fi
if ! networksetup -listpreferredwirelessnetworks en0 | sed '1d;s/^[[:space:]]*//' | grep -Fxq -- "$normal_ssid"; then
  echo 'Your normal SSID is not saved. No network changed.' >&2
  exit 2
fi
if [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]]; then
  echo 'Return to normal internet first. No network changed.' >&2
  exit 2
fi
echo 'WARNING: v6 is a REAL, intentionally failing OTA experiment. It may require USB recovery.'
echo 'Only proceed if the controller remains connected to USB and v4 recovery binaries are retained.'
read -r -p 'Type ROLLBACK to authorize this ONE signed v6 upload: ' confirmation
[[ "$confirmation" == ROLLBACK ]] || { echo 'Cancelled; no network changed.'; exit 1; }
mkdir -p "$ROOT/test_logs"
log="$ROOT/test_logs/controller-v6-$(date +%Y%m%d-%H%M%S).log"
echo "Local test log: $log"
exec > >(tee -a "$log") 2>&1
restore_network() {
  rc=$?
  trap - EXIT INT TERM
  echo "Returning to saved Wi-Fi: $normal_ssid"
  connected=0
  for try in 1 2 3; do
    if networksetup -setairportnetwork en0 "$normal_ssid"; then
      for wait in 1 2 3 4 5; do
        sleep 2
        if curl --noproxy '*' --connect-timeout 2 --max-time 4 -fsSI https://github.com >/dev/null 2>&1; then
          connected=1; break
        fi
      done
    fi
    (( connected )) && break
  done
  if (( ! connected )); then
    echo 'Usual Wi-Fi not back yet; trying auto-join...'
    networksetup -setairportpower en0 off || true
    sleep 2
    networksetup -setairportpower en0 on || true
    sleep 5
    curl --noproxy '*' --connect-timeout 2 --max-time 4 -fsSI https://github.com >/dev/null 2>&1 && connected=1
  fi
  if (( connected )); then
    echo "Internet is back. Check saved test log: $log"
  else
    echo "WARNING: reconnect to usual Wi-Fi manually. Check saved log: $log"
  fi
  exit "$rc"
}
trap restore_network EXIT INT TERM

echo 'Joining OTA-CLASS-DEMO for one controlled signed-v6 failure test.'
networksetup -setairportnetwork en0 OTA-CLASS-DEMO demo-ota-1234
ready=0
for try in {1..25}; do
  [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] && { ready=1; break; }
  sleep 2
done
(( ready )) || { echo 'Demo AP unavailable; NO v6 upload sent.'; exit 1; }
before=$(curl --noproxy '*' --connect-timeout 3 --max-time 5 -fsS http://192.168.4.1/status)
echo "Preflight: $before"
[[ "$before" == *"role=0 version=5"* && "$before" == *"ota=valid"* ]] || {
  echo 'v5 is NOT confirmed valid; NO v6 upload sent.'; exit 1;
}
# Helper checks signature and device state again. Pre-authorized above BEFORE disconnecting.
printf 'ROLLBACK\n' | "$ROOT/host_signing/send_rollback_test.sh" 6
echo 'Accepted upload is not evidence of rollback; independently checking boot result.'
confirmed=0
for try in {1..30}; do
  if [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" != 192.168.4.* ]]; then
    networksetup -setairportnetwork en0 OTA-CLASS-DEMO demo-ota-1234 >/dev/null 2>&1 || true
  fi
  state=$(curl --noproxy '*' --connect-timeout 2 --max-time 3 -fsS http://192.168.4.1/status 2>/dev/null || true)
  if [[ "$state" == *"role=0 version=5"* && "$state" == *"ota=valid"* &&
        "$state" == *"last_invalid="* && "$state" != *"last_invalid=none"* ]]; then
    echo "PASS: failed v6 rolled back to valid v5; rejected slot recorded: $state"
    confirmed=1
    break
  fi
  if [[ "$state" == *"role=0 version=6"* ]]; then
    echo "FAIL: controller reports v6 instead of reverting: $state"
    break
  fi
  sleep 2
done
(( confirmed )) || { echo 'Rollback NOT proven. Do NOT retry v6; inspect status/serial or USB recover.'; exit 1; }
echo 'STOP: failure-driven rollback demonstrated on controller only. Do not resend v6.'
