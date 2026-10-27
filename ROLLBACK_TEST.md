# Controller first-boot rollback: hardware verified; edge negative tests pending

Current physical state: **controller runs secure v5 with `ota=valid` after a deliberately failing v6 OTA was rolled back; both edges run secure v4** (see SECURE_OTA.md). The controller was read-only identified as classic ESP32, 4 MB flash, MAC `20:50:0d:1b:64:d8` on `/dev/cu.usbserial-110` (port may change). The signed controller v4 image and manifest are retained under ignored `secure_firmware/controller_v4/` and passed local signature verification. A success-path first-boot confirmation and a failure-path rollback are both hardware-tested **on the controller only**; neither power-loss recovery nor edge-device rollback has been tested.

## Edge rejection tests (no flashing)

The controller now runs secure v5 with `ota=valid`, and both edges must be powered and still on v4. **If your Mac needs its normal Wi-Fi for internet/assistant access, do not manually join the demo AP.** Instead run `./host_signing/offline_edge_tests.sh 'YOUR_USUAL_WIFI_NAME'` locally from your normal Wi-Fi; it runs both probes in order, saves a log in ignored `test_logs/`, and attempts to restore internet (best effort; manual reconnection may be necessary). Do not rerun automatically if a probe or connection fails. Alternatively, while already joined to `OTA-CLASS-DEMO`, run the probes manually:

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

## Offline controlled rollback test — COMPLETED ON CONTROLLER; DO NOT RERUN

On 2026-10-28, `./host_signing/offline_controller_v6.sh 'AUMobile-WiFi_AR'` prompted for explicit `ROLLBACK` confirmation before disconnecting the Mac from the internet. It preflighted `role=0 version=5 ... ota=valid last_invalid=none`, locally verified the signed v6 image, sent it **once**, and got `Signed image accepted; rebooting`. After reboot the independent controller `/status` read **`role=0 version=5 ... ota=valid last_invalid=app1`**. This is evidence that the *deliberately failing signed v6 image* was rejected at first boot and the previous working v5 slot resumed. The Mac's usual internet Wi-Fi returned. The complete local log is ignored at `test_logs/controller-v6-20261028-042838.log`. **Do not run the v6 script again.**

## First-boot rollback on controller only

The installed Arduino-ESP32 core 3.3.12 was checked locally: `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=1`. But Arduino's weak `verifyOta()` default unconditionally approves an OTA image during early initialization. On this development branch we override `verifyRollbackLater()` to defer approval until `setup()` can check libsodium and live controller AP / edge Wi-Fi connection. On first boot of a newly OTA-installed image, a passing check calls `esp_ota_mark_app_valid_cancel_rollback()`, while a failing check calls `esp_ota_mark_app_invalid_rollback_and_reboot()`. A compile-time `FORCE_SELF_TEST_FAILURE=1` is for the deliberately failing v6 test image **only**; never USB-flash v6.

The project build script `./build_rollback.sh` already compiled and signed two 4MB-ESP32 images (under ignored `rollback_firmware/`):

- controller v5: healthy self-test; installed OTA from v4 and confirmed itself on hardware (`ota=valid`).
- controller v6: signed and valid transfer, deliberately fails first-boot self-test, and **reverted to v5 on hardware**. The v6 build is a controlled *test*, not a release.

Images fit the 1.25 MB OTA slots. A compiler symbol check of v5 shows `verifyRollbackLater` as a **strong** definition and the Arduino default `verifyOta` as weak. **Both v5 and v6 experiments have now succeeded; do not rerun either one.** The currently booted controller v5 reports `ota=valid last_invalid=app1`. Keep the proven v4 recovery binaries and USB recovery available.

The new firmware's `/status` includes `ota=` (state of its running image) and `last_invalid=` (most recent rejected slot) as diagnostic evidence; the older v4 does not expose these fields. The v6 script refused to run until v5 reported `ota=valid`. A missing AP or no reply would **not** have proved rollback. The preceding v4 slot was replaced during the v5/v6 sequence; recovery uses USB if the firmware/bootloader fails.

## Limits

A self-test that checks AP/connection and crypto initialization does not detect every faulty firmware image. Rollback covers an update failing *first-boot verification*, not crashes after confirmation. No eFuse hardware anti-rollback or Secure Boot was enabled. Version checking remains software-only; a physically reflashed device can bypass it. Noise-style link encryption is NOT implemented by this branch. An updated compile-only `crypto_probe/crypto_probe.ino` linked libsodium X25519 key exchange and ChaCha20-Poly1305 AEAD on classic ESP32; **this is not an authenticated handshake, a network channel, or runtime proof**. Before claiming a secure link, peer identities must be bound to pre-provisioned trusted public keys, session keys derived from a defined handshake transcript, fresh unique AEAD nonces enforced in both directions, and replay/malformed-packet tests run. Do not call a custom channel full Noise IK or claim this probe provides confidentiality.
