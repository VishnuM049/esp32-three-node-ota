# Noise link hardware gate — **NOT EXECUTED**

**Existing hardware is still proven signed OTA:** controller v5 (valid, failed v6 rolled back); edge1/edge2 v4. No ESP32 has been flashed with this candidate. Do not perform this gate casually before a presentation: all three roles must migrate together. `NOISE_LINK_PLAN.md` is the security contract.

## Before touching USB

1. Provide stable power to the Mac/boards, identify each serial port independently (it can change), and make an **independent encrypted off-repo backup** of `private_keys/noise/` and `private_keys/demo.pem`. Never paste, email, commit, or copy identities into a plaintext folder. Ensure the backup is restorable without disclosing its contents. Keep recovery images/scripts for the existing v5/v4 builds; never resend historical failed controller v6.
2. Confirm `feature/noise-link` and review the Noise-C port/license, framing, NVS provisioning, built images and the remaining test gaps. `./test_noise_host_vectors.sh`, `PYTHONPATH=host_signing .venv/bin/python -m unittest discover -s host_signing -q`, `./build_noise_firmware.sh --bootstrap`, and `./build_noise_firmware.sh --ota-targets` must pass. Build scripts do **not** flash. The USB candidate contains its own static secret; signed OTA candidates do **not**. `send_noise_signed.sh` refuses to upload if a provisioned private key is found in the OTA `.bin`. Do not override this check.
3. In particular, **do not** send any `*_encrypted_v7` controller USB image or `*_encrypted_v6` edge USB image over the AP: Mac→controller HTTP is plaintext and those USB images contain long-term private keys. USB bootstrap writes each role's private key to NVS once, and refuses to replace a different installed identity. NVS is not encrypted at rest; this does not stop physical flash extraction. OTA images contain public pins and read the matching NVS private key on boot.

## Controlled, one-board-at-a-time USB bootstrap (requires explicit human confirmation)

From this repository, with a verified physical serial port for the chosen role:

```sh
./flash_noise_bootstrap.sh edge1 /dev/cu.usbserial-<verify>
./flash_noise_bootstrap.sh edge2 /dev/cu.usbserial-<verify>
./flash_noise_bootstrap.sh controller /dev/cu.usbserial-<verify>
```

The script checks branch, fresh source/image, per-role private bytes, 4 MB classic ESP32, and the recorded hardware **MAC** before prompting twice. Controller MAC `20:50:0d:1b:64:d8`, edge1 `a4:f0:0f:66:5a:18`, edge2 `8c:94:df:4c:b7:88`. Do not force a failed check. During partial migration the edge/controller link will **not** work; this is expected, not permission to enable plaintext fallback. Bring all boards back to the OTA-CLASS-DEMO AP after completing USB flashes and allow registration time. No sender should run until status proves both edges authenticated.

## Runtime gate, *before* any OTA

On the Mac (temporarily connected to `OTA-CLASS-DEMO`; Mac internet will be interrupted), query `curl --noproxy '*' --max-time 20 http://192.168.4.1/status` repeatedly. Record timestamps, status strings, version, OTA state, `minheap`, `stack_margin` and `rtt` for both edges, plus `min_heap` / `stack_margin` for controller. Expected starting versions: controller v7, edge1 and edge2 v6; controller `noise=1`; both edges must appear as `edge1_secure=v6_ota...` and `edge2_secure=v6_ota...`. No plaintext edge HTTP `/update` can be present. Test an unauthenticated connection to port 8080 without uploading an image; it must not alter status. Inspect serial if there is an NVS or Noise error. If a registration fails or memory/stack margin collapses, **STOP and diagnose or USB-recover**, not downgrade to plaintext or attempt OTA. Restore the Mac's saved internet Wi-Fi afterwards.

## Signed OTA gate, only after successful runtime observation

The following sender performs strict local signature, version, current-state and **no-embedded-private-key** checks, and makes **one** HTTP upload through controller port 80. Host→controller is still plaintext, and firmware contents are visible on that hop. There is no automatic retry of a timeout/ambiguous response:

```sh
# While on OTA-CLASS-DEMO, independently send ONE at a time; check /status after each:
./host_signing/send_noise_signed.sh edge1      # v6→v7 over pinned Noise
./host_signing/send_noise_signed.sh edge2      # v6→v7 over pinned Noise
./host_signing/send_noise_signed.sh controller # v7→v8, direct signed controller OTA
```

For each edge, wait for registration and record `edgeN_secure=v7_ota2...` (ESP-IDF `ESP_OTA_IMG_VALID=2`), heap/stack minima and RTT. Controller v8 should report `ota=valid`, `noise=1`, with both edges still registered. If the response drops near reboot, check status/serial before doing anything: **never resend blindly**. Then schedule bounded negative tests for forged role/peer, malformed/truncated/replayed frames, plaintext edge update, interrupted/tampered encrypted OTA, hash failures, and edge rollback individually; preserve log and flash state. These are **pending hardware tests**, not demonstrated properties. Restore the saved Mac Wi-Fi after the session.
