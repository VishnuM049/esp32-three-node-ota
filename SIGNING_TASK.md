# Teammate handoff — host-side signing work (independent of the boards)

The current code is a **transport prototype, not secure OTA**. Read `README.md` first. DO NOT edit `ota_prototype.ino`, `build_all.sh`, or existing firmware binaries while the transport is being tested. Put your files in a new `host_signing/` folder so work can be merged without conflicts.

Your separate task: build a laptop-side Python Ed25519 signing tool using a maintained crypto library (e.g. Python `cryptography`), **not custom curve math**. It should:

1. Generate a private/public key pair. Keep the private key OUT of the shared ZIP/repository; export only the public key for the device. Don't embed a sample private key in board firmware.
2. Given a compiled `.bin`, a target role (0 controller / 1 edge 1 / 2 edge 2) and positive version number, compute SHA-256 of the exact binary, create unambiguous signed metadata (role, version, length, hash, format identifier), and sign it with Ed25519. Choose a fixed documented byte layout and test that each field is covered by the signature.
3. Implement a laptop verifier for tests: valid -> pass; modified firmware / altered version / wrong role / wrong key / truncated or unsigned manifest -> reject. Test with `python -m unittest` or `pytest` without any ESP32.
4. Document precise byte layout, key format, exact CLI commands, and how to export the 32-byte public key for ESP32 verification. Give the layout to the device-code developer BEFORE integration. Be aware that merely writing a host signer does NOT secure OTA: the ESP32 must check role/version, hash, and signature before selecting an update for boot.

Proposed compact format to agree on first: 4-byte ASCII `OTA1`, 1-byte role, 4-byte LE unsigned version, 4-byte LE unsigned length, 32-byte SHA-256 image digest, then 64-byte Ed25519 signature over the preceding 45 bytes. The `.bin` is transmitted separately. Treat this as a proposed interface; communicate any change before coding it into device firmware. The controller forwards binary and manifest unchanged. Do not call this Noise or use X25519 for firmware signing.

This task has **no hardware dependency** and can run on any laptop. Do not claim the security feature is complete until the ESP32 verifier rejects bad images in an end-to-end test.
