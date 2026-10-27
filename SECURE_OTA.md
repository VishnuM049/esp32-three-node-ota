# Signed OTA development branch — DO NOT claim hardware success until tests pass

Public repo contains ONLY `TrustedPublicKey.h` (public verification key), not the private Ed25519 key. This branch is a separate security implementation; `main` preserves the previously demonstrated unsigned three-node v1/v2 transport. **Do not use old `test_controller_ota.sh`, `firmware/*_v2` or `flash_initial.sh` for the security demo.**

## Implemented (software; hardware testing still required)

- Mac signer: `host_signing/manifest.py` uses Python cryptography Ed25519 and hashes raw `.bin` using SHA-256. Generates exactly 109-byte OTA1 manifests: 45 signed metadata bytes + 64 signature bytes. `host_signing/test_manifest.py` tests valid and invalid cases offline.
- ESP32 code: libsodium Ed25519 verification of metadata *before* writing an update, role/length/version checks, then streaming SHA-256 of received image and comparison *before* calling `Update.end(false)` (which selects the image for next boot). Wrong signatures and hashes abort the update. Controller forwards the unchanged `X-OTA-Manifest` header and image; edges independently verify it.
- The public key is compiled into each image. Private key stays in ignored `private_keys/demo.pem` on the signing laptop (mode 0600). This is a classroom demonstration key, not production key management. Never commit or share the private key.
- `./build_secure.sh` produces role-specific secure v3 bootstrap and secure v4 OTA binaries in ignored `secure_firmware/`. Both versions use the SAME public key. v3 must be USB-flashed once to each device because old v2 does not verify signatures.

## Commands (from repo root on Mac)

```bash
# Python 3.9+ with cryptography installed (e.g. uv venv --python /usr/bin/python3 .venv && uv pip install --python .venv/bin/python cryptography)
PYTHONPATH=host_signing .venv/bin/python -m unittest discover -s host_signing -v
# Keygen is ONE-TIME ONLY. It refuses to overwrite an existing key.
.venv/bin/python host_signing/manifest.py keygen
./build_secure.sh
for role in controller edge1 edge2; do
  case "$role" in controller) id=0;; edge1) id=1;; edge2) id=2;; esac
  bin="secure_firmware/${role}_v4/ota_prototype.ino.bin"
  .venv/bin/python host_signing/manifest.py sign --image "$bin" --role "$id" --version 4
  .venv/bin/python host_signing/manifest.py verify --image "$bin" --manifest "$bin.manifest" --role "$id" --current-version 3
done
```

The above host steps have run and passed on this laptop. Do NOT run keygen a second time; losing/replacing the private key would make the existing public key in firmware incompatible.

## Hardware testing sequence (controller complete; edges NOT COMPLETE)

1. The known controller board was USB-flashed with secure **controller v3** using `./flash_secure.sh controller /dev/cu.usbserial-110`; its upload hash verified. Boot was confirmed by `GET /status` returning `role=0 version=3`. An unsigned POST to `/update` returned HTTP 403 `Missing or malformed signed manifest`; a subsequent status check still returned v3. The controller rejected all four metadata probe cases (`Invalid developer signature`, `Wrong target role`, `Old or repeated version`, and altered signed version) and remained on v3. `host_signing/probe_tampered_image.py` sent a full modified v4 image with a genuine v4 manifest; the controller returned HTTP 403 `Image SHA-256 does not match signed manifest` and stayed at v3. A valid signed controller v4 image was then sent over Wi-Fi: the controller replied `Signed image accepted; rebooting`, and an independent `GET /status` after reboot confirmed `role=0 version=4`. **Signed OTA is proven on the controller only.** The edges still run old unsigned v2; keep the old binaries for recovery if needed.
2. The known 4 MB edge2 board (MAC `8c:94:df:4c:b7:88`) was USB-flashed with **secure edge2 v3** and the upload hash verified; its network boot/status has **not yet been checked** because the controller is currently unplugged. The controller is already secure v4. Edge1 still needs secure v3 bootstrap on its Micro-USB board after reading its chip/flash size. Use the correct role for each. This initial USB setup is the trust bootstrap; OTA thereafter must be signed.
3. The controller is already secure v4. Once each edge runs secure v3, join `OTA-CLASS-DEMO` on the Mac and run `./host_signing/send_signed.sh edge2` once; after edge2 reboots, check controller `/status` for its IP and check edge status directly for `role=2 version=4`. Do the same for edge1. The script refuses if its intended target is not secure v3.
4. Explicitly test signed wrong-role, tampered image, modified manifest, unsigned and old-version requests on secure v3 devices; all must reject, and `/status` must remain v3. If v4 already installed, use signed version 4 again to test replay rejection without changing it. **Do not claim security until on-device negative tests are recorded.**

## Honest threat model / outstanding work

This is **application-level signed OTA**, not hardware secure boot. Someone able to physically reflash the ESP32 can replace its verifier or public key. Version `> FW_VERSION` is a software downgrade check only; it is NOT eFuse anti-rollback, not a tamper-proof persistent version counter, and recovery to an older working slot may complicate version handling. Post-boot self-test rollback and Noise-style authenticated encryption are **not implemented**. The demo AP password alone does not establish trust; the developer signature does. Protect the demo private key, and do not use this for production devices.
