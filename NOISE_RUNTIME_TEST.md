# Noise hardware run — partial final-state failure (2026-10-28)

**DO NOT resend signed images to repeat this run.** These are observed hardware results, not an audited or fully tested security product. Mac→controller HTTP remains plaintext. The app OTA targets contained no provisioned raw X25519 key bytes; bootstrap USB binaries did contain one private identity each.

## Completed

- One-time USB trust bootstrap with MAC and 4 MB flash checks, ESP32 flash hash verification: controller `20:50:0d:1b:64:d8` → v7, edge1 `a4:f0:0f:66:5a:18` → v6, edge2 `8c:94:df:4c:b7:88` → v6. The local AES-256 encrypted identity/signing-key backup was checked against 12 source files; remote iCloud sync was **not** checked. All three booted; controller `/status` returned `noise=1` and both edges reported authenticated v6 status in the same query.
- Initial simultaneous v6 registration: edge1 `v6_ota255_minheap215348_stack10832_rttms335`, edge2 `v6_ota255_minheap213712_stack10832_rttms300`; controller `minheap195008 stack_margin9468`. USB factory OTA state 255 means unknown, **not** a failed signed OTA.
- Exactly one signed OTA edge1 v6→v7 through pinned Noise; controller HTTP returned **"Authenticated edge accepted signed image"**. Status showed edge1 `v7_ota1` (pending) then `v7_ota2` (ESP-IDF valid), with edge2 still registered.
- Exactly one signed OTA edge2 v6→v7 through pinned Noise; controller HTTP returned authenticated acceptance. Status showed edge2 `v7_ota1` then `v7_ota2`, and edge1 still `v7_ota2`. The controller reported `minheap165532 stack_margin8652` after both edge uploads. These are runtime minima measured by this sketch, not a worst-case guarantee.
- Exactly one signed laptop→controller OTA v7→v8 (this hop was **plaintext HTTP**). HTTP returned **"Signed image accepted; rebooting"**. Controller rebooted and `/status` independently reported `role=0 version=8 noise=1 ota=valid` with `minheap201084 stack_margin12716` in a subsequent sample. Edge status was **unregistered** after controller reboot.

## Current blocker / do not overclaim

For over 40 seconds after controller v8 reboot, both edges remained unregistered. A subsequent check found edge2's USB serial port had disappeared, so loss of power or USB connectivity is plausible but **not established** as the only cause. No firmware was resent. Ask the user to verify both edge boards have power and press EN/RESET on each, leaving controller on; then query controller `/status` for `edge1_secure=v7_ota2_...` and `edge2_secure=v7_ota2_...` simultaneously. If absent, inspect serial and debug reconnection. Do **not** claim an all-three-working final v8/v7/v7 constellation yet.

Noise negative tests on the live ESP32 links (wrong pin/role, replay, tamper, malformed frames, plaintext port and interrupted upload), packet capture, physical key extraction protection, and edge rollback remain untested. Desktop KK vectors/negative tests and earlier signed-OTA hardware negatives are separate evidence in `NOISE_LINK_PLAN.md`, `ROLLBACK_TEST.md`.
