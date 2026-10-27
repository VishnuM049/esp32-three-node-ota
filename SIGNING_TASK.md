# Signing protocol specification — teammate owns implementation

**Repo:** https://github.com/VishnuM049/esp32-three-node-ota (PUBLIC). Coordinate this format with `TEAMMATE_TASK.md` before implementation. Never commit the private key or paste it in an issue.

The current code is a **transport prototype, not secure OTA**. Read `README.md` first. DO NOT edit `ota_prototype.ino`, `build_all.sh`, or existing firmware binaries while the transport is being tested. Put your files in a new `host_signing/` folder so work can be merged without conflicts.

Your separate task: build a laptop-side Python Ed25519 signing tool using a maintained crypto library (e.g. Python `cryptography`), **not custom curve math**. It should:

1. Generate a private/public key pair. Keep the private key OUT of the shared ZIP/repository; export only the public key for the device. Don't embed a sample private key in board firmware.
2. Given a compiled `.bin`, a target role (0 controller / 1 edge 1 / 2 edge 2) and positive version number, compute SHA-256 of the exact binary, create unambiguous signed metadata (role, version, length, hash, format identifier), and sign it with Ed25519. Choose a fixed documented byte layout and test that each field is covered by the signature.
3. Implement a laptop verifier for tests: valid -> pass; modified firmware / altered version / wrong role / wrong key / truncated or unsigned manifest -> reject. Test with `python -m unittest` or `pytest` without any ESP32.
4. Document precise byte layout, key format, exact CLI commands, and how to export the 32-byte public key for ESP32 verification. Give the layout to the device-code developer BEFORE integration. Be aware that merely writing a host signer does NOT secure OTA: the ESP32 must check role/version, hash, and signature before selecting an update for boot.

## Fixed manifest format for integration (agree on changes BEFORE implementing them)

Exactly 109 bytes, no JSON, padding, newline, or ambiguous text encoding:

| Offset | Size | Field |
|---|---:|---|
| 0 | 4 | ASCII `OTA1` |
| 4 | 1 | role: 0 controller / 1 edge1 / 2 edge2 |
| 5 | 4 | unsigned version, little endian |
| 9 | 4 | unsigned image byte length, little endian |
| 13 | 32 | SHA-256 digest of the exact raw `.bin` |
| 45 | 64 | Ed25519 detached signature of bytes 0..44 |

Version must be positive. The raw `.bin` is sent as the request body with exact Content-Length equal to signed image length. The 109-byte manifest is hex-encoded as **218 lowercase hexadecimal characters** in one `X-OTA-Manifest` HTTP header. The controller relays *exactly the same* manifest header and image to the destination; it must not re-sign. The destination checks format, role, signature, signed length, version and full streamed image SHA-256 before calling `Update.end()` to select it for boot. Missing/duplicate/invalid manifest must be rejected. A private key is never copied to any ESP32 or committed publicly. Never represent a host-only signature test as device-side OTA protection.

**Toolchain finding:** The locally installed Arduino ESP32 core 3.3.12 already ships a compiled Espressif libsodium library. A compile-only sketch using `#include <sodium.h>`, `sodium_init()` and `crypto_sign_verify_detached()` linked successfully on classic ESP32. Device-side verification can use those existing primitives rather than porting libsodium separately. This has **not yet been boot-tested**; test actual valid and invalid signatures on hardware. Binary size must be checked against the 1.25 MB OTA slot.

This task has **no hardware dependency** for host tests. Device integration and end-to-end negative tests DO need hardware. Do not call this Noise or use X25519 for firmware signing. Do not claim the security feature is complete until the ESP32 verifier rejects bad images in an end-to-end test.
