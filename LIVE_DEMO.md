# Live OTA demo, prepared but **NOT YET SENT**

**Current boards, verified in `NOISE_RUNTIME_TEST.md`:** controller **v8** (`ota=valid`), edge1 **v7** (`ota2=valid`), edge2 **v7** (`ota2=valid`). Both edges authenticated with Noise when powered. Existing v8/v7 images **cannot be resent**: the signed version checks deliberately reject duplicates. This document provides **newer** signed images for a *single future live update*. Do not rehearse with them and expect to use the same versions again on stage.

`./build_noise_firmware.sh --demo-next` has prepared ignored role-specific **key-free** OTA binaries plus 109-byte Ed25519 signed manifests: edge1 **v8**, edge2 **v8**, and controller **v9**. No board was changed by this build. The Mac→controller upload remains **plaintext HTTP on the same AP**; only controller→edge OTA, status and registration use pinned Noise KK. Do not claim end-to-end firmware secrecy. Never upload/share USB-bootstrap images containing static private keys.

## Before the presentation

For an offline preflight and a complete viva explanation, use [`OFFLINE_VIVA_GUIDE.md`](OFFLINE_VIVA_GUIDE.md). Run `./host_signing/offline_demo_check.sh` **before leaving**; it never uploads, flashes or changes Wi-Fi.

1. Charge the Mac. Keep the proven boards and all three USB/NVS identities as-is. Back up the ignored `noise_experiments/*_encrypted_v8_build/` edge and `controller_encrypted_v9_build/` **locally in an encrypted location** if you need to move Macs; do not publish firmware artifacts. The signing identity backup is separate.
2. Power **controller first**, then both edges. Give them 10–20 seconds to register. If they do not re-register after a controller reboot, unplug/replug **edge power only**; this manual workaround was needed in the hardware run. Do not flash or resend an image to fix registration.
3. Optionally start the **Mac-local browser web log** in a separate Terminal: `python3 web_log/server.py`, then open `http://127.0.0.1:8765/`. See `WEB_LOG.md`; it is read-only and logs future observations. Connect Mac Wi-Fi to `OTA-CLASS-DEMO` (password `demo-ota-1234`). This temporarily interrupts normal internet. `curl --noproxy '*' --max-time 20 http://192.168.4.1/status` must show controller `role=0 version=8 noise=1 ota=valid`, `edge1_secure=v7_ota2_...`, `edge2_secure=v7_ota2_...` **in the same response**. If not, STOP and diagnose power/registration; sender refuses to upload.

## On stage: real version change, one use per role

From this repository on the demo AP:

```sh
./host_signing/send_noise_demo_next.sh edge1
# Watch: Before edge1=v7_ota2; HTTP authenticated acceptance; After edge1=v8_ota2 (possibly v8_ota1 briefly).
./host_signing/send_noise_demo_next.sh edge2
# Watch: both edges now v8_ota2 and authenticated. Controller is still v8 valid.
```

**Stop here for the simplest, most reliable live demonstration.** This already shows signed image transfer over both encrypted controller→edge links and destination-side version/first-boot verification. You can also show a plaintext HTTP `GET /update` to an edge's port 8080 getting no HTTP response, but do **not** send a real plaintext image or run destructive negative tests on stage. Show the earlier rejection/rollback evidence from `ROLLBACK_TEST.md` separately and label it accurately.

**Optional controller update, last:** `./host_signing/send_noise_demo_next.sh controller` changes controller **v8→v9** over the *plaintext Mac→controller hop*, verifies `ota=valid`, and reboots the AP. Edges may **not** reconnect automatically; power-cycle them individually, then query `/status` again for controller v9 and both edges v8 valid. Do not do this optional step unless power, time and access to edge cables are available.

**Never retry an ambiguous upload without independent status/serial checks.** The script checks signer manifest, image, key absence, current role/version, both authenticated edge states and valid boots; it performs one upload and polls status, not another upload. Once v8 edges or v9 controller have booted, these files are spent. To repeat the presentation, compile and sign strictly higher versions; do not regenerate identities or signing keys. Restore the Mac's saved internet Wi-Fi after the demo.

## Accurate one-line explanation

"The laptop submits a developer-signed image to the controller over demo HTTP. The controller uses pinned Noise KK to authenticate/encrypt its link to each edge. Every destination independently verifies the Ed25519 signature, role, newer version and full SHA-256 before booting, then reports its valid boot state. The laptop hop is plaintext, physical extraction is not prevented, and automatic edge reconnect/edge rollback were not proven."
