#!/bin/bash
# Interactive, password-protected off-repo backup. Run in a Mac Terminal,
# never via chat or a logged automation session. No plaintext archive is made.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/private_keys"
CLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
[[ -t 0 ]] || { echo 'Run this interactively in Terminal (do not send the passphrase in chat).' >&2; exit 1; }
[[ -f "$SRC/demo.pem" && -f "$SRC/noise/controller.x25519" &&
   -f "$SRC/noise/edge1.x25519" && -f "$SRC/noise/edge2.x25519" ]] || {
  echo 'Required local private keys missing; no backup created.' >&2; exit 1;
}
[[ -d "$CLOUD" ]] || { echo 'iCloud Drive is unavailable; no backup created.' >&2; exit 1; }
echo 'This creates an AES-256 encrypted disk image of private_keys/ in iCloud Drive.'
echo 'Choose a NEW strong passphrase (20+ characters), store it in your password manager.'
echo 'NEVER paste the passphrase or keys into chat. It will not appear while typing.'
read -r -s -p 'Backup passphrase: ' pass; echo
read -r -s -p 'Confirm passphrase: ' confirm; echo
[[ ${#pass} -ge 20 && "$pass" == "$confirm" ]] || {
  unset pass confirm
  echo 'Passphrases differ or are shorter than 20 characters; no backup created.' >&2; exit 1;
}
unset confirm
TEMP=$(mktemp -d "$HOME/.esp32-encrypted-backup.XXXXXX")
mount="$TEMP/mount"
mkdir -m 700 "$mount"
mounted=0
cleanup() {
  if (( mounted )); then hdiutil detach "$mount" >/dev/null || return 1; fi
  rm -rf "$TEMP"
}
trap cleanup EXIT
image="$TEMP/ota-private-keys.dmg"
printf '%s\n' "$pass" | hdiutil create -srcfolder "$SRC" -volname ESP32-OTA-Private-Backup \
  -format UDZO -encryption AES-256 -stdinpass "$image" >/dev/null
chmod 600 "$image"
printf '%s\n' "$pass" | hdiutil attach -readonly -nobrowse -stdinpass \
  -mountpoint "$mount" "$image" >/dev/null
mounted=1
unset pass
python3 - "$SRC" "$mount" <<'PY'
from pathlib import Path
import hashlib, sys
src, mounted = (Path(p) for p in sys.argv[1:])
base = mounted if (mounted / 'demo.pem').is_file() else mounted / 'private_keys'
files = [p for p in src.rglob('*') if p.is_file()]
if len(files) < 5:
    raise SystemExit('Too few files in source; backup NOT verified')
for original in files:
    copy = base / original.relative_to(src)
    if not copy.is_file() or hashlib.sha256(original.read_bytes()).digest() != hashlib.sha256(copy.read_bytes()).digest():
        raise SystemExit('Encrypted image content does NOT match the source; backup NOT verified')
print(f'Encrypted image mounted and checked against {len(files)} source files (no key contents displayed).')
PY
hdiutil detach "$mount" >/dev/null
mounted=0
destination="$CLOUD/ESP32-Encrypted-Backup"
mkdir -p "$destination"
chmod 700 "$destination"
target="$destination/ota-private-keys-$(date +%Y%m%d-%H%M%S).dmg"
[[ ! -e "$target" ]] || { echo 'Backup name collision; refusing overwrite.' >&2; exit 1; }
cp "$image" "$target"
chmod 600 "$target"
cmp -s "$image" "$target" || { rm -f "$target"; echo 'Copied image does not match; no verified cloud backup.' >&2; exit 1; }
echo "Encrypted backup created and locally verified: $target"
echo 'IMPORTANT: Cloud sync is not verified. Check this .dmg appears in iCloud Drive on another device.'
echo 'Keep its passphrase independently in your password manager; without it the backup cannot be restored.'
