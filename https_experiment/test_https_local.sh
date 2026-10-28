#!/bin/bash
# Offline tests of certificates and compile-only artifacts. No Wi-Fi or boards.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT="$ROOT/private_keys/host_tls/server.crt"
KEY="$ROOT/private_keys/host_tls/server.key"
IMG="$ROOT/noise_experiments/https_controller_v10_candidate_build/https_controller_v10_candidate.ino.bin"
USB="$ROOT/noise_experiments/https_controller_v10_usb_private_build/https_controller_v10_usb_private.ino.bin"
[[ -s "$CERT" && -s "$KEY" && -s "$IMG" && -s "$USB" ]] || exit 1
openssl verify -CAfile "$CERT" "$CERT"
openssl x509 -in "$CERT" -noout -checkip 192.168.4.1 | grep -q 'does match'
if openssl x509 -in "$CERT" -noout -checkip 192.168.4.2 | grep -q 'does match'; then
  echo 'Wrong-IP certificate erroneously matched' >&2; exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj '/CN=wrong-controller' -keyout "$TMP/wrong.key" -out "$TMP/wrong.crt" >/dev/null 2>&1
if openssl verify -CAfile "$TMP/wrong.crt" "$CERT" >/dev/null 2>&1; then
  echo 'Wrong trust anchor erroneously verified' >&2; exit 1
fi
ROOT="$ROOT" "$ROOT/.venv/bin/python" - <<'PY'
from pathlib import Path
import os
r = Path(os.environ['ROOT'])
image = (r/'noise_experiments/https_controller_v10_candidate_build/https_controller_v10_candidate.ino.bin').read_bytes()
usb = (r/'noise_experiments/https_controller_v10_usb_private_build/https_controller_v10_usb_private.ino.bin').read_bytes()
key = (r/'private_keys/host_tls/server.key').read_bytes()
assert key not in image and key in usb
assert b'POST image with valid Content-Length required' not in image
assert b'Firmware uploads require verified HTTPS port 443' in image
for role in ('controller','edge1','edge2'):
    noise = (r/'private_keys/noise'/f'{role}.x25519').read_bytes()
    assert len(noise) == 32 and noise not in image and noise not in usb
sender = (r/'https_experiment/send_https_edge.sh').read_text()
assert ' --cacert "$CERT"' in sender and '--insecure' not in sender
print('Checked certificate hostname/trust rejection, key-free OTA, USB-only key, no HTTP upload path.')
PY
