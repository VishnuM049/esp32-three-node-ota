# Isolated HTTPS Mac → controller candidate (NOT hardware validated)

**Branch:** `feature/https-host-experiment`. Proven `feature/noise-link` source and prepared v9 controller / v8 edge images were **not rebuilt, flashed or uploaded**. Do not claim that the live boards currently use HTTPS. No OTA POST or Wi-Fi configuration is changed by any build/test command here.

## Implemented in candidate source

- Controller v10-only candidate accepts firmware POSTs on port **443** with ESP-IDF's HTTPS server; port 80 retains **read-only GET /status** and rejects **all** plaintext firmware POSTs. Port 8081 / edges' port 8080 still use pinned Noise KK for peer status and signed streaming.
- Developer signature, signed role/version/length, and full SHA-256 are checked at the receiver as before. TLS uploads are streamed in 1,024-byte chunks; edges still independently verify. No HTTP fallback. First-boot controller confirmation now requires the HTTPS listener to start.
- TLS ECDSA P-256 certificate/private key are distinct from Ed25519 signing key and X25519 Noise keys. New certificate has SAN IP `192.168.4.1`; the Mac sender uses `curl --cacert` (not `-k`). The **private TLS key is loaded from a separate NVS namespace**, not in the OTA candidate binary.
- `build_https_candidate.sh --usb` makes a **key-bearing, USB-ONLY** v10 candidate that can provision TLS cert/key into NVS. It is *not* an OTA image and must never be posted over HTTP/HTTPS or shared. `build_https_candidate.sh --ota` makes a key-free candidate, but **does not sign or send it**. Both builds are ignored locally. `send_https_edge.sh --check` would verify a running candidate's cert without uploading; `--send edge1|edge2` would require an explicit typed confirmation and consume that prepared signed edge v8 version.

## Local-only test result

`build_https_candidate.sh --ota` compiled: **1,137,328 / 1,310,720 bytes**. `--usb` compiled: **1,138,928 / 1,310,720 bytes**. `https_experiment/test_https_local.sh` passed: positive certificate trust and IP matching, wrong-IP/wrong-trust rejection, actual TLS key absent from OTA binary and present only in USB build, all three provisioned raw X25519 private identities absent, and plaintext HTTP POST code absent from candidate. **No TLS handshake, runtime memory, encrypted upload, wrong-certificate Mac probe, packet capture, or live rollback has been tested on ESP32 hardware.** Size fit alone proves nothing about TLS runtime heap or stability.

Local ignored certificate/key/header: `private_keys/host_tls/server.crt`, `private_keys/host_tls/server.key`, `noise_experiments/https_tls_bootstrap/TlsBootstrapPrivate.h`. These are **not** in GitHub or the existing encrypted key backup; do not lose/share the private key or any USB key-bearing image. Cert has ten-year validity but an offline Mac's local clock must still be correct.

## Why hardware deployment is deliberately paused

An existing v8 controller has **no NVS TLS certificate/key**. Sending the key-free v10 over its plaintext HTTP update route cannot provision TLS and should fail first-boot self-test/roll back. To run this candidate, one must intentionally identify and **USB flash the actual controller** with the locally key-bearing USB-only image. This replaces the currently proven v8 controller and would invalidate the reserved controller v9 one-shot path; the edges may require manual power cycles. A wrong port or erase of NVS could also destroy its provisioned Noise identity. **Get explicit permission and a serial/MAC check before any USB flash.** We have not done that. Do not claim both hops encrypted until a real, certificate-verified Mac HTTPS upload to an edge is followed by authenticated edge v8 `ota2` and memory/security tests.

## Known limitations / next checks

- This is a **candidate**, not production-grade hardened TLS. The ESP32 stores its TLS key in plain NVS (physical extraction possible); Wi-Fi AP clients are not mutually authenticated by TLS, although signed firmware still restricts accepted images. Controller sees the decrypted image between two secure hops; no end-to-end confidentiality against a malicious controller.
- Measure TLS handshake/firmware relay minimum heap, TLS task stack and peer registrations together. Test certificate mismatch on actual Mac, HTTP POST refusal, interrupted upload, bad signature, incomplete/forged hash, controller rollback, and passive packet capture before claiming security. The HTTP status endpoint remains plaintext, and a compromised controller can still lie to the laptop.
- Original presentation plan remains on `feature/noise-link`: controller v8 and one-use edge v8 updates via *plaintext laptop HTTP*, unless the owner explicitly chooses to sacrifice that plan for the HTTPS hardware experiment.
