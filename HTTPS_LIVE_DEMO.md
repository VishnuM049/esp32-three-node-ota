# New one-use HTTPS + Noise presentation — prepared, NOT sent

**Last independently confirmed physical constellation (2026-10-28):** controller **v11** (`ota=valid noise=1 tls=1`), edge1 **v9** (`ota2`), edge2 **v9** (`ota2`). Both edges authenticated simultaneously after an actual controller v11 HTTPS OTA reboot; two controller-only resets also demonstrated unattended re-registration for both. Mac→controller **firmware uploads** use pinned HTTPS; controller→edge uses pinned Noise KK. **Read-only HTTP `/status` is plaintext**. There is no end-to-end secrecy from a malicious controller. Full results, including failed edge1 v8 first-boot confirmation and later successful v9, in `HTTPS_RUNTIME_TEST.md`.

**New, signed but unsent local artifacts:** edge1 v10, edge2 v10 (`noise_experiments/edge{1,2}_reconnect_v10_demo_build/*.ino.bin` + `.manifest`); optional controller v12 (`noise_experiments/https_controller_v12_demo_build/*.ino.bin` + `.manifest`). All built for this Mac, role-specific, verified, key-free and <=1,310,720-byte OTA slot. They are **not in Git**. No version may be replayed after installation; do not rehearse with these images.

## Before presenting (offline)

1. On this **same Mac**, run `./host_signing/offline_https_demo_check.sh`. It checks the three local signed images/manifest pairs, their slot fit and private-byte absence, certificate/key match, local tests and commands. It sends **no** image and does **not** contact boards or switch Wi-Fi.
2. Supply stable USB power to **controller and both edges**. Allow 20–30 seconds. Join `OTA-CLASS-DEMO` (password `demo-ota-1234`) and independently check:
   ```sh
   curl --noproxy '*' --max-time 25 http://192.168.4.1/status
   ```
   One response **must** contain `role=0 version=11 noise=1 tls=1 ... ota=valid`, `edge1_secure=v9_ota2_...`, and `edge2_secure=v9_ota2_...`. AP connection has no internet; that is expected. If missing, **STOP**, inspect board power/registration; do not send anything to repair registration.
3. Optionally open `http://127.0.0.1:8765/` on the Mac with `python3 web_log/server.py`; this page is read-only. For the highest first-boot reliability, **stop its status poller during the one-shot edge update**, then restart it afterward. The sender records started/accepted/confirmed/ambiguous events to a local file even when the page server is stopped. The earlier experimental v8 first-boot attempt failed under concurrent status polling; its cause was not isolated, so don't claim the page is harmless under all timing loads.

## Stage sequence, no blind retries

```sh
cd ~/iot_project_abstracts/ota_prototype
./host_signing/send_https_demo_next.sh edge1      # v9 -> v10; one use
# Check edge1_secure=v10_ota2_ in authenticated controller status.
./host_signing/send_https_demo_next.sh edge2      # v9 -> v10; one use
# Check both edges v10_ota2, controller v11 valid.
```

The sender checks Mac AP IP, public-key signature, role, strictly newer signed version, image size, raw private-key absence, healthy baseline status **for both edges**, and a verified controller HTTPS handshake (`--cacert`, never `-k`). It uploads **exactly once**, waits quietly for edge first-boot registration, then queries authenticated status. If response/confirmation is ambiguous, **STOP** and inspect status/serial; do not automatically resend. `ota1` is pending and is **not** a successful new boot. `ota2` is confirmed/valid.

**Optional last step:** after **both** edges report `v10_ota2_` and controller remains v11 valid, run `./host_signing/send_https_demo_next.sh controller` for **v11→v12** over pinned HTTPS. The controller will reboot its AP; the script may be unable to re-query if the Mac auto-roams. Rejoin the demo AP as needed and independently confirm `role=0 version=12 noise=1 tls=1 ota=valid` and both authenticated v10 edges. No firmware resend. Stop after the two edge updates for the lower-risk presentation.

**After demo:** rejoin the Mac's normal Wi-Fi (previously `AUMobile-WiFi_AR`). The sender and local browser log do **not** change Wi-Fi automatically. Keep the Mac plugged in. If any edge truly loses power, software reconnect cannot operate until it is powered again.

## Accurate talking points

> "The Mac verifies the controller's certificate and uploads a developer-signed image over HTTPS on the local demo AP. The controller decrypts it and relays the unchanged signed image over its pinned Noise KK channel to the chosen edge. The edge independently checks role, version, signature, length and full hash before boot. Its confirmed OTA state and version return over Noise. Both edges re-registered without manual power cycles in the tested controller-reboot runs. The read-only status page remains HTTP, a previous v8 edge first boot did roll back, no packet capture or physical key-at-rest protection is claimed, and the two secure hops are not end-to-end secrecy against a malicious controller."

**Do not use the older `LIVE_DEMO.md` or `send_noise_demo_next.sh`:** they gate on controller v8/edge v7 and plaintext Mac upload and will correctly refuse this v11/v9/v9 setup. Never send key-bearing USB bootstrap images over either HTTP or HTTPS; keep signed OTA artifacts key-free. The ignored controller v8 full-flash snapshot is an unencrypted local, private, untested-restore fallback—not an off-site verified backup.
