#!/bin/bash
# Read-only/offline: validates future one-use controller12/edge10 artifacts. NO boards touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="$ROOT/.venv/bin/python"
[[ -x "$PY" ]] || { echo 'Missing local Python signing dependency' >&2; exit 1; }
"$PY" -c 'import cryptography'
for tool in curl xxd networksetup ipconfig python3 openssl git; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done
for file in private_keys/demo.pem private_keys/demo_public.bin \
  private_keys/host_tls/server.crt private_keys/host_tls/server.key \
  private_keys/noise/controller.x25519 private_keys/noise/edge1.x25519 \
  private_keys/noise/edge2.x25519 web_log/server.py; do
  [[ -s "$file" ]] || { echo "Missing local file $file; GitHub does not hold private identities" >&2; exit 1; }
done
openssl verify -CAfile private_keys/host_tls/server.crt private_keys/host_tls/server.crt >/dev/null
openssl x509 -in private_keys/host_tls/server.crt -noout -checkip 192.168.4.1 | grep -q 'does match'
[[ "$(openssl pkey -in private_keys/host_tls/server.key -pubout | openssl dgst -sha256)" == \
   "$(openssl x509 -in private_keys/host_tls/server.crt -pubkey -noout | openssl dgst -sha256)" ]] || {
  echo 'TLS cert/private mismatch' >&2; exit 1;
}
for role in edge1 edge2 controller; do
  case "$role" in
    edge1) id=1; current=9; next=10; name=edge1_reconnect_v10_demo;;
    edge2) id=2; current=9; next=10; name=edge2_reconnect_v10_demo;;
    controller) id=0; current=11; next=12; name=https_controller_v12_demo;;
  esac
  image="noise_experiments/${name}_build/${name}.ino.bin"
  [[ -s "$image" && -s "$image.manifest" ]] || {
    echo "Missing local signed $role v$next demo image/manifest; NO upload" >&2; exit 1;
  }
  for artifact in "$image" "$image.manifest"; do
    git check-ignore -q "$artifact" || { echo "STOP: candidate no longer ignored: $artifact" >&2; exit 1; }
  done
  "$PY" host_signing/manifest.py verify --public private_keys/demo_public.bin \
    --image "$image" --manifest "$image.manifest" --role "$id" --current-version "$current"
  "$PY" - "$image" <<'PY'
from pathlib import Path
import sys
image = Path(sys.argv[1]).read_bytes()
assert 0 < len(image) <= 0x140000, 'Wrong OTA slot size'
secrets=[Path('private_keys/noise',f'{role}.x25519').read_bytes()
         for role in ('controller','edge1','edge2')]
secrets.append(Path('private_keys/host_tls/server.key').read_bytes())
assert all(s not in image for s in secrets), 'STOP: private identity in OTA binary'
PY
  echo "LOCALLY READY / UNSENT: $role v$current -> v$next. Does NOT prove current board state."
done
PYTHONPATH=host_signing "$PY" -m unittest discover -s host_signing -q
python3 -m unittest discover -s web_log -p 'test_*.py' -q
ip=$(ipconfig getifaddr en0 2>/dev/null || :)
if [[ "$ip" == 192.168.4.* ]]; then
  echo 'Mac on demo AP; still GET controller /status and verify v11/v9/v9 before sending.'
else
  echo 'Mac not on demo AP (normal offsite check); no network changes made.'
fi
echo 'HTTPS DEMO OFFLINE PREFLIGHT PASSED. No OTA, USB, AP switch, or device contact.'
