#!/bin/bash
# Offline, local-only. Generates one separate TLS identity for optional USB bootstrap.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/private_keys/host_tls" # ignored; never commit
CERT="$DIR/server.crt"
KEY="$DIR/server.key"
HEADER="$ROOT/noise_experiments/https_tls_bootstrap/TlsBootstrapPrivate.h" # ignored
mkdir -p "$DIR" "$(dirname "$HEADER")"
if [[ -e "$CERT" || -e "$KEY" ]]; then
  [[ -s "$CERT" && -s "$KEY" ]] || { echo 'Partial TLS identity: STOP, no rotation' >&2; exit 1; }
else
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 3650 \
    -subj '/CN=192.168.4.1' -addext 'subjectAltName=IP:192.168.4.1' \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
  openssl pkey -in "$KEY" -out "$DIR/server.pkcs8" >/dev/null 2>&1
  mv "$DIR/server.pkcs8" "$KEY"
fi
openssl verify -CAfile "$CERT" "$CERT" >/dev/null
openssl x509 -in "$CERT" -noout -checkip 192.168.4.1 | grep -q 'does match'
[[ "$(openssl pkey -in "$KEY" -pubout | openssl dgst -sha256)" == \
   "$(openssl x509 -in "$CERT" -pubkey -noout | openssl dgst -sha256)" ]] || {
  echo 'Certificate/private-key mismatch; STOP' >&2; exit 1;
}
python3 - "$CERT" "$KEY" "$HEADER" <<'PY'
from pathlib import Path
import sys
cert, key, header = map(Path, sys.argv[1:])
assert '-----BEGIN CERTIFICATE-----' in cert.read_text()
assert '-----BEGIN PRIVATE KEY-----' in key.read_text()
for text in (cert.read_text(), key.read_text()):
    assert ')OTATLS"' not in text and len(text) < 3000
header.write_text('// USB BOOTSTRAP ONLY. CONTAINS A PRIVATE KEY. NEVER COMMIT OR OTA.\n'
                  'static const char TLS_BOOTSTRAP_CERT[] = R"OTATLS(' + cert.read_text() + ')OTATLS";\n'
                  'static const char TLS_BOOTSTRAP_KEY[] = R"OTATLS(' + key.read_text() + ')OTATLS";\n')
header.chmod(0o600)
PY
chmod 600 "$KEY" "$CERT"
echo 'Prepared ignored TLS certificate and USB-only provisioning header. NO BOARD TOUCHED.'
echo "Public Mac trust anchor: $CERT (do not use curl -k)."
