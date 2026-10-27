#!/bin/bash
# A single unattended v4 -> healthy v5 signed OTA test. NEVER sends v6.
# Run locally in Terminal; pass YOUR usual saved Wi-Fi SSID (not password).
# Internet is briefly unavailable. Results persist under ignored test_logs/.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
normal_ssid="${1:-}"
if [[ -z "$normal_ssid" || "$normal_ssid" == "OTA-CLASS-DEMO" ]]; then
  echo "Usage: $0 'YOUR_USUAL_WIFI_NAME' (SSID only; do NOT enter its password)" >&2
  exit 2
fi
# Fail before touching Wi-Fi if the fallback network is not saved on this Mac.
if ! networksetup -listpreferredwirelessnetworks en0 | sed '1d;s/^[[:space:]]*//' | grep -Fxq -- "$normal_ssid"; then
  echo "Your normal SSID is not in the saved Wi-Fi list. No network changed." >&2
  exit 2
fi
if [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]]; then
  echo "Already on demo Wi-Fi; please return to normal internet before this offline test." >&2
  exit 2
fi
mkdir -p "$ROOT/test_logs"
log="$ROOT/test_logs/controller-v5-$(date +%Y%m%d-%H%M%S).log"
echo "Local test log: $log"
exec > >(tee -a "$log") 2>&1
restore_network() {
  rc=$?
  trap - EXIT INT TERM
  echo "Returning to your saved Wi-Fi: $normal_ssid"
  connected=0
  for try in 1 2 3; do
    if networksetup -setairportnetwork en0 "$normal_ssid"; then
      for wait in 1 2 3 4 5; do
        sleep 2
        if curl --noproxy '*' --connect-timeout 2 --max-time 4 -fsSI https://github.com >/dev/null 2>&1; then
          connected=1
          break
        fi
      done
    fi
    (( connected )) && break
  done
  if (( ! connected )); then
    echo 'Normal Wi-Fi did not regain internet. Trying automatic Wi-Fi rejoin...'
    networksetup -setairportpower en0 off || true
    sleep 2
    networksetup -setairportpower en0 on || true
    sleep 5
    if curl --noproxy '*' --connect-timeout 2 --max-time 4 -fsSI https://github.com >/dev/null 2>&1; then
      connected=1
    fi
  fi
  if (( connected )); then
    echo 'Internet is back. Read this log for OTA result:' "$log"
  else
    echo "WARNING: reconnect to your usual Wi-Fi manually in the Wi-Fi menu. Log: $log"
  fi
  exit "$rc"
}
trap restore_network EXIT INT TERM

echo 'Joining OTA-CLASS-DEMO. This script will send healthy v5 ONCE, never v6.'
networksetup -setairportnetwork en0 OTA-CLASS-DEMO demo-ota-1234
ready=0
for try in {1..25}; do
  [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] && { ready=1; break; }
  sleep 2
done
(( ready )) || { echo 'Demo network did not assign an IP; NO update sent.'; exit 1; }
before=$(curl --noproxy '*' --connect-timeout 3 --max-time 5 -fsS http://192.168.4.1/status)
echo "Preflight: $before"
[[ "$before" == *"role=0 version=4"* ]] || { echo 'Not controller v4; NO update sent.'; exit 1; }
# This helper checks local signature and current device version again before ONE POST.
"$ROOT/host_signing/send_rollback_test.sh" 5
confirmed=0
for try in {1..25}; do
  # On ESP32 reboot macOS may automatically switch Wi-Fi; try rejoining.
  if [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" != 192.168.4.* ]]; then
    networksetup -setairportnetwork en0 OTA-CLASS-DEMO demo-ota-1234 >/dev/null 2>&1 || true
  fi
  state=$(curl --noproxy '*' --connect-timeout 2 --max-time 3 -fsS http://192.168.4.1/status 2>/dev/null || true)
  if [[ "$state" == *"role=0 version=5"* && "$state" == *"ota=valid"* ]]; then
    echo "PASS: controller first-boot validation completed: $state"
    confirmed=1
    break
  fi
  if [[ "$state" == *"role=0 version=4"* ]]; then
    echo "FAIL: controller returned to v4; v5 did not confirm: $state"
    break
  fi
  sleep 2
done
(( confirmed )) || { echo 'No v5 ota=valid confirmation. DO NOT SEND v6 or automatically retry v5.'; exit 1; }
echo 'STOP: v5 confirmed. v6 is a separate manual experiment; do not send it unattended.'
