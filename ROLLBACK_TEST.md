# Next experiments (NOT yet demonstrated on hardware)

Physical state as of the first hardware rollback preparation test: **controller runs secure v5 with `ota=valid`; both edges run secure v4** (see SECURE_OTA.md). The connected controller was read-only identified as classic ESP32, 4 MB flash, MAC `20:50:0d:1b:64:d8` on `/dev/cu.usbserial-110` (port may change). The signed controller v4 image and manifest are retained under ignored `secure_firmware/controller_v4/` and passed local signature verification. First-boot success/confirmation is hardware-tested on the controller; *failure-driven rollback is not yet tested*.

## Edge rejection tests (no flashing)

Once all 3 boards are powered, join `OTA-CLASS-DEMO` and run:

```bash
python3 host_signing/probe_edge_rejections.py
```

The first script reads both registered edge addresses from the controller, requires both to report v4, and sends only HTTP *headers* for unsigned, wrong-role, replayed v4, and forged-version manifests directly to each edge. It expects HTTP 403 for every case and confirms each remains v4. Do not claim this succeeded until you have the output.

For a **separate** full-image hash-rejection test on both edges, `./build_edge_negative.sh` has already compiled and signed valid v5 images; the probe authenticates each original image locally, flips a byte of the body **in memory**, and sends ONLY the tampered copy with its unmodified valid signed manifest. Each edge should reject with HTTP 403 and remain v4. Never send the original uncorrupted v5 image as part of this negative test. After the header probe passes, run the following **once** while all boards are on and the Mac is still on the demo Wi-Fi:

```bash
./.venv/bin/python host_signing/probe_edge_tampered.py
```

A lost Wi-Fi connection, HTTP error or missing status is NOT a pass; do not automatically retry. The two probes have been syntax-checked but not run on hardware.

## Single-command offline v5 test (Mac stays charging)

If talking to the assistant requires the Mac's current internet Wi-Fi, **do not simply join the demo AP and wait for instructions**. Instead, once you are at the Mac, run `./host_signing/offline_controller_v5.sh 'YOUR_USUAL_WIFI_NAME'` from your normal network. Give only the SSID of a network already saved on this Mac, **not its password**. The script preflights that name, temporarily joins the demo AP, sends signed controller v5 **once** only if the controller reports v4, confirms `role=0 version=5 ota=valid` after reboot, and attempts to restore your saved Wi-Fi on exit. Its output is saved in the ignored `test_logs/` directory. **Internet will be unavailable briefly. Auto-reconnection is best effort, not guaranteed; be ready to choose your usual Wi-Fi manually if it fails.** If the result is missing/ambiguous, do not retry or send v6. This script was run **once on the controller** on 2026-10-28: it confirmed v4 before sending, locally validated the signed v5 image, got `Signed image accepted; rebooting`, then independently queried `role=0 version=5 ... ota=valid last_invalid=none`. The Mac successfully returned to `AUMobile-WiFi_AR`. Local log: ignored `test_logs/controller-v5-20261028-042452.log`.

## Offline controlled rollback test (not yet run)

After the controller v5 result above, the intentionally failing v6 test can run locally without keeping the assistant online. This test **may leave the controller needing USB recovery**. Do not run if you cannot recover by USB. From your normal Wi-Fi with the controller on USB power, run:

```bash
./host_signing/offline_controller_v6.sh 'YOUR_USUAL_WIFI_NAME'
```

The script requires you to type `ROLLBACK` **before** changing networks. It requires v5 with `ota=valid`, checks the v6 developer signature, sends v6 **once** and never retries. After reboot it requires `role=0 version=5 ota=valid` and a non-`none` `last_invalid` slot before calling it a pass; then it tries to restore your usual internet Wi-Fi and saves a log under ignored `test_logs/`. Recovery of the Mac's network is best effort. It has passed shell syntax and failure-preflight checks, but failure-driven rollback has **not** yet been observed on hardware.

## First-boot rollback on controller only

The installed Arduino-ESP32 core 3.3.12 was checked locally: `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=1`. But Arduino's weak `verifyOta()` default unconditionally approves an OTA image during early initialization. On this development branch we override `verifyRollbackLater()` to defer approval until `setup()` can check libsodium and live controller AP / edge Wi-Fi connection. On first boot of a newly OTA-installed image, a passing check calls `esp_ota_mark_app_valid_cancel_rollback()`, while a failing check calls `esp_ota_mark_app_invalid_rollback_and_reboot()`. A compile-time `FORCE_SELF_TEST_FAILURE=1` is for the deliberately failing v6 test image **only**; never USB-flash v6.

The project build script `./build_rollback.sh` already compiled and signed two 4MB-ESP32 images (under ignored `rollback_firmware/`):

- controller v5: healthy self-test; installed OTA from v4 and confirmed itself on hardware (`ota=valid`).
- controller v6: signed and valid transfer, but deliberately fails first-boot self-test; should revert to v5. The v6 build is a controlled *test*, not a release.

Images fit the 1.25 MB OTA slots. A compiler symbol check of v5 shows `verifyRollbackLater` as a **strong** definition and the Arduino default `verifyOta` as weak. First-boot confirmation succeeded on hardware, but this is not proof of failure-driven rollback. **Do not rerun v5**: it is already installed and reports `role=0 version=5 ota=valid`. Keep the proven v4 recovery binaries and USB recovery available. For v6, prefer the offline script above; the manual alternative while joined to the demo AP is `./host_signing/send_rollback_test.sh 6`, then rejoin the demo AP if needed and independently check `/status` for `role=0 version=5 ota=valid` and a non-`none` `last_invalid` slot.

The new firmware's `/status` includes `ota=` (state of its running image) and `last_invalid=` (most recent rejected slot) as diagnostic evidence; the older v4 does not expose these fields. The v6 script refuses to run unless v5 reports `ota=valid`. Run each **once**; if the Mac switches back to its usual Wi-Fi during reboot, rejoin the ESP32 AP rather than re-sending an image. If v5 does not boot, STOP and recover via USB; do not send v6. A missing AP or no reply after v6 is NOT proof of rollback. The preceding v4 slot may be replaced during the v5 install; recovery uses USB if the firmware/bootloader fails.

## Limits

A self-test that checks AP/connection and crypto initialization does not detect every faulty firmware image. Rollback covers an update failing *first-boot verification*, not crashes after confirmation. No eFuse hardware anti-rollback or Secure Boot was enabled. Version checking remains software-only; a physically reflashed device can bypass it. Noise-style link encryption is NOT implemented by this branch. An updated compile-only `crypto_probe/crypto_probe.ino` linked libsodium X25519 key exchange and ChaCha20-Poly1305 AEAD on classic ESP32; **this is not an authenticated handshake, a network channel, or runtime proof**. Before claiming a secure link, peer identities must be bound to pre-provisioned trusted public keys, session keys derived from a defined handshake transcript, fresh unique AEAD nonces enforced in both directions, and replay/malformed-packet tests run. Do not call a custom channel full Noise IK or claim this probe provides confidentiality.
