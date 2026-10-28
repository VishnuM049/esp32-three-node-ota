# HTTPS controller experiment: live partial success, edge first-boot rollback

**Experimental branch only. Do not merge to `main` or claim completed two-hop OTA yet.** Signed/Noise `main` remains untouched; controller v8 full flash is retained locally under ignored, mode-0600 `private_keys/flash_snapshots/full_controller_*/` (unencrypted local backup, not an independently tested restore).

## 2026-10-28 controller USB / Mac TLS tests

- Physically identified USB controller MAC `20:50:0d:1b:64:d8`, classic ESP32 4 MB. USB flashed key-bearing **v10** experimental HTTPS build only after twice-verifying the controller v8 full flash in 64 KiB chunks and matching its signed v8 app in the OTA1 partition. Flash upload hash verified. This changes controller firmware and OTA selection; edge flash/NVS unchanged.
- Controller `/status`: `role=0 version=10 noise=1 tls=1 ota=unknown`. `ota=unknown` follows a USB bootstrap, **not** a signed v10 OTA valid boot. Certificate-verified Mac `curl --cacert private_keys/host_tls/server.crt https://192.168.4.1/no-upload` completed TLS handshake (expected 404). Wrong local trust anchor rejected (`curl` exit 60). Plaintext HTTP `POST /update` with a harmless one-byte body rejected (403). HTTP GET `/status` intentionally remains plaintext.
- Edges initially did not re-register unattended after controller reboot. Manual power cycles of **edge power only** restored simultaneous authenticated `edge1_secure=v7_ota2_... edge2_secure=v7_ota2_...`. This is **still not** automatic reconnection.

## First HTTPS → Noise edge1 OTA attempt: failed first-boot confirmation

- Exactly one HTTPS-upload attempt of the prepared, validly signed edge1 **v8** image: controller replied `Authenticated edge accepted signed image; rebooting`. New edge1 briefly appeared as **`v8_ota1` pending**, with status RTT ~10.09 seconds. Edge2 remained v7 valid.
- ~30 seconds later edge1 was observed **back on v7 `ota2`**. Sender printed `STOP: no confirmed healthy boot` and exited nonzero. Controller TLS/Ota minimum free heap after transfer was about **98,704 bytes**, stack margin around **10,688 bytes** as exposed by its loop-task status (not TLS task stack). These are diagnostic samples, not stability guarantees. No second upload or edge2 OTA was attempted.
- A Mac web-log process (`web_log/server.py`) was discovered running concurrently, polling the controller's synchronous `/status` every ~8 seconds; the sender also polled after acceptance every ~3 seconds. The single controller Arduino loop handles `/status` by synchronously opening authenticated Noise status sessions to BOTH edges, which can block for many seconds while edge1's first-boot code is trying to register to the controller's peer listener. **Starvation/timing is a hypothesis, not yet a proven root cause.** The status observation `v8_ota1` is not evidence that REGISTER_OK or `esp_ota_mark_app_valid_cancel_rollback()` succeeded. Logs from edge1 during its pending first boot are needed.

**Stop condition:** Do not blindly resend edge1 v8 or use edge2 v8 until the rollback cause is diagnosed. The v8 image's first transfer succeeded, but the updated app did **not** confirm a healthy boot; no completed two-hop OTA claim is supported yet. Existing original `main` evidence remains valid for controller v8 and the earlier encrypted edge v7 run. Mac Wi-Fi was returned to its normal network after every status/upload check; HTTPS private material remains in ignored local USB-only build/NVS and is not in OTA candidate binaries or Git.

## Next controlled tests

1. Attach edge1 USB serial while controller stays powered; capture association/REGISTER_OK/rollback messages on a deliberate **new-version** diagnostic run. Preserve original keys and original failed v8 image; don't auto-retry it.
2. Prevent concurrent web-log polling during first-boot verification, delay sender status polling, and/or revise controller to service peer registration ahead of expensive synchronous GET `/status` queries. Consider a longer bounded edge first-boot timeout with the same authenticated requirement. Recompile/sign **new** edge versions and test under load before merging anything.
3. Independently verify no plaintext image leaks (packet capture), accepted and rejected image paths, TLS task heap/stack, controller own signed HTTPS OTA and rollback. Then test automatic edge reconnection after a controller-only reboot with both edge power lines untouched.
