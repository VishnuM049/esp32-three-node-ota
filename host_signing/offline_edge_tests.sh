#!/bin/bash
# Locally test both edges while Mac is temporarily on demo AP; restore internet.
# Sends header-only negatives and ONE tampered full image per edge; never valid v5.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
normal_ssid="${1:-}"
if [[ -z "$normal_ssid" || "$normal_ssid" == OTA-CLASS-DEMO ]]; then
  echo "Usage: $0 'YOUR_USUAL_WIFI_NAME' (saved SSID, not password)" >&2; exit 2
fi
if ! networksetup -listpreferredwirelessnetworks en0 | sed '1d;s/^[[:space:]]*//' | grep -Fxq -- "$normal_ssid"; then
  echo 'Normal SSID is not saved; NO network change.' >&2; exit 2
fi
for role in 1 2; do
  [[ -f "$ROOT/rollback_firmware/edge${role}_v5/ota_prototype.ino.bin.manifest" ]] || {
    echo "Missing signed edge${role} v5 negative-test image; NO network change." >&2; exit 2;
  }
done
mkdir -p "$ROOT/test_logs"
log="$ROOT/test_logs/edge-negative-$(date +%Y%m%d-%H%M%S).log"
echo "Local log: $log"
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
    echo 'Internet not back yet; trying automatic Wi-Fi rejoin...'
    networksetup -setairportpower en0 off || true
    sleep 2
    networksetup -setairportpower en0 on || true
    sleep 5
    curl --noproxy '*' --connect-timeout 2 --max-time 4 -fsSI https://github.com >/dev/null 2>&1 && connected=1
  fi
  if (( connected )); then echo "Internet restored. Read log: $log"
  else echo "Reconnect Wi-Fi manually. Read log: $log"; fi
  exit "$rc"
}
trap restore_network EXIT INT TERM

echo 'Joining OTA-CLASS-DEMO. No valid v5 images will be sent.'
networksetup -setairportnetwork en0 OTA-CLASS-DEMO demo-ota-1234
ready=0
for try in {1..25}; do
  [[ "$(ipconfig getifaddr en0 2>/dev/null || :)" == 192.168.4.* ]] && { ready=1; break; }
  sleep 2
done
(( ready )) || { echo 'Demo AP not available; no test performed.'; exit 1; }
echo 'Header-only direct-edge rejection tests:'
"$ROOT/.venv/bin/python" "$ROOT/host_signing/probe_edge_rejections.py"
echo 'Full-image hash rejection tests (tampered v5 bodies only):'
"$ROOT/.venv/bin/python" "$ROOT/host_signing/probe_edge_tampered.py"
echo 'STOP: both edge tests completed. No valid firmware update was sent.'
