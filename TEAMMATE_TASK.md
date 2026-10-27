# Teammate handoff — edge board AND firmware security

**Public repo:** https://github.com/VishnuM049/esp32-three-node-ota

```bash
git clone https://github.com/VishnuM049/esp32-three-node-ota.git
cd esp32-three-node-ota
```

Read `README.md` and `SIGNING_TASK.md` first. This is a **transport prototype, not yet secure OTA**. The working controller board is with Vishnu; you have the Micro-USB edge board. Work on a separate branch, e.g. `teammate-signing`, and send a pull request. Do not commit private signing keys, passwords, machine-specific settings or huge build caches. Because the repo is PUBLIC, never paste real secrets in issues or commits.

## Your primary deliverable: Ed25519 signed OTA (substantial coding)

1. **Laptop signing tool** in `host_signing/` (see the now-fixed 109-byte format and `X-OTA-Manifest` header in `SIGNING_TASK.md`). Use a maintained Python library (`cryptography`); no custom curve math. Generate a private/public key pair locally. The private key stays on your laptop and must never be committed. Emit a binary manifest and a 32-byte public key that can be embedded in firmware; sign exact image digest + target role + version + length. Implement negative tests (changed image, wrong key, wrong role, altered version, missing/truncated manifest).
2. **ESP32-side verification module** in new files such as `SignedUpdate.h/.cpp`, leaving `ota_prototype.ino` alone so our edits do not conflict. Follow the fixed binary manifest layout in `SIGNING_TASK.md`. The installed Arduino ESP32 core 3.3.12 already includes libsodium Ed25519 (compile-only test passed); try `#include <sodium.h>` and `crypto_sign_verify_detached()` rather than porting another crypto library. Do NOT implement cryptography yourself. Expose a small API for checking signed metadata, image SHA-256 and target role/version. Investigate how to check the incoming image's complete hash **before selecting it as the next boot image**; simply checking a manifest without checking the image is not sufficient. Report any library/flash-size blocker rather than weakening security silently.
3. **Integration handoff:** write `docs/security-integration.md` showing exact functions/call order, required library installation, build instructions, and how to inject the public key. Submit your module and tests as a PR; we will merge it into the controller/edge transport code here. A host-only signer does not make OTA secure: ESP32-side rejection tests must pass before we claim it.

Prioritize (1) then (2). If hardware/time blocks (2), submit (1), tests, and the precise interface so we can finish device integration. Anti-downgrade, boot rollback, and Noise-style link encryption are **additional** requirements, not completed by Ed25519 alone. Do not promise them without tests.

## Hardware deliverable: Micro-USB edge 1

4. Obtain a Micro-USB **data** cable, connect the board, and verify a USB serial port appears (`ls /dev/cu.usb*` on a Mac). Check exact chip and flash size. Report it to us. The supplied binaries/partition table are for **classic ESP32, 4 MB flash**; do not flash an unverified different chip/size.
5. Initial-flash **edge1 v1** with `./flash_initial.sh edge1 /dev/cu.usbserial-...` once your Arduino IDE 2 + Espressif ESP32 core are installed on your computer. The repo contains prebuilt v1 binaries, but the script needs Arduino CLI bundled with Arduino IDE. The script will ask for confirmation. Do not choose controller/edge2 for this board. At 115200 serial baud, it should try to join Wi-Fi `OTA-CLASS-DEMO` when the controller is powered nearby.
6. With controller nearby, confirm it registers at `http://192.168.4.1/status` and responds at `http://<edge-ip>:8080/status`. Send boot messages and failures. Only after that, coordinate an edge1 v2 OTA through the controller, then prove edge1 reports version 2. **Physical relay has not been tested yet.** Record your results in `docs/edge1-test.md`.

Vishnu/assistant will run the controller's v1→v2 Wi-Fi OTA test, integrate your verification module, handle controller/edge2 flashing once the replacement arrives, and test end-to-end. Share problems early; do not wait until the final hour to report a blocker.
