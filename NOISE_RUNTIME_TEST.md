# Noise hardware run — signed OTA succeeded; manual reconnection required (2026-10-28)

**DO NOT resend signed images to repeat this run.** For new one-time live-demo images and instructions, see `LIVE_DEMO.md`. These are observed hardware results, not an audited or fully tested security product. Mac→controller HTTP remains plaintext. The app OTA targets contained no provisioned raw X25519 key bytes; bootstrap USB binaries did contain one private identity each.

## Completed

- One-time USB trust bootstrap with MAC and 4 MB flash checks, ESP32 flash hash verification: controller `20:50:0d:1b:64:d8` → v7, edge1 `a4:f0:0f:66:5a:18` → v6, edge2 `8c:94:df:4c:b7:88` → v6. The local AES-256 encrypted identity/signing-key backup was checked against 12 source files; remote iCloud sync was **not** checked. All three booted; controller `/status` returned `noise=1` and both edges reported authenticated v6 status in the same query.
- Initial simultaneous v6 registration: edge1 `v6_ota255_minheap215348_stack10832_rttms335`, edge2 `v6_ota255_minheap213712_stack10832_rttms300`; controller `minheap195008 stack_margin9468`. USB factory OTA state 255 means unknown, **not** a failed signed OTA.
- Exactly one signed OTA edge1 v6→v7 through pinned Noise; controller HTTP returned **"Authenticated edge accepted signed image"**. Status showed edge1 `v7_ota1` (pending) then `v7_ota2` (ESP-IDF valid), with edge2 still registered.
- Exactly one signed OTA edge2 v6→v7 through pinned Noise; controller HTTP returned authenticated acceptance. Status showed edge2 `v7_ota1` then `v7_ota2`, and edge1 still `v7_ota2`. The controller reported `minheap165532 stack_margin8652` after both edge uploads. These are runtime minima measured by this sketch, not a worst-case guarantee.
- Exactly one signed laptop→controller OTA v7→v8 (this hop was **plaintext HTTP**). HTTP returned **"Signed image accepted; rebooting"**. Controller rebooted and `/status` independently reported `role=0 version=8 noise=1 ota=valid` with `minheap201084 stack_margin12716` in a subsequent sample. Edge status was **unregistered** after controller reboot.

## Final three-board status and reconnection limitation

For over 40 seconds after controller v8 reboot, both edges remained unregistered. Edge2's USB serial port disappeared; loss of power or USB connectivity was plausible but **not proven** as the sole cause. The controller AP briefly vanished and returned after a read-only MAC probe reset it. No firmware was resent. The user then power-cycled **both edges** (unplug/replug), leaving the controller powered. Two subsequent controller `/status` requests confirmed the **same final constellation simultaneously**:

`role=0 version=8 noise=1 edge1=192.168.4.2 edge2=192.168.4.3 edge1_secure=v7_ota2_minheap214024_stack10844_rttms334 edge2_secure=v7_ota2_minheap213468_stack10844_rttms315 ota=valid last_invalid=none heap=201956 minheap=183364 stack_margin=9468`

The first status immediately after edge restart took 11,790 ms for edge2; the next took 315 ms. **Do not claim unattended reconnect after a controller reboot**: manual edge power cycles were required in this run, and the cause was not isolated. This is a demonstration of signed OTA through authenticated encrypted links with all three boards valid, not proof of automatic power-loss recovery.

A bounded plaintext HTTP `GET /update` to **each** edge's port 8080 received no HTTP response (`curl` code 52, HTTP 000, zero response bytes). Subsequent authenticated `/status` still reported both edges `v7_ota2` and controller v8 valid. This is a basic fail-closed smoke test, **not** a full negative suite or a plaintext image-upload attempt.

Noise negative tests on the live ESP32 links (wrong pin/role, replay, tamper, malformed frames and interrupted upload), packet capture, physical key extraction protection, and edge rollback remain untested. Desktop KK vectors/negative tests and earlier signed-OTA hardware negatives are separate evidence in `NOISE_LINK_PLAN.md`, `ROLLBACK_TEST.md`.
