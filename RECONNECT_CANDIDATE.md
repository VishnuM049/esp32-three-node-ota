# Edge auto-rejoin candidate (not yet hardware proven)

**Branch:** `feature/reconnect-candidate`, cut from the proven signed/Noise `main`. The installed controller v8 and edges v7, their NVS identities, and the prepared unsent edge v8/controller v9 images are not changed by this branch.

The installed edge code calls `WiFi.reconnect()` roughly every 500 ms when disconnected. That may disrupt an in-progress Wi-Fi association; however, the prior failure after a controller reboot had a possible USB/power loss too, so this is a **hypothesis**, not a confirmed root cause. A physically unpowered edge cannot rejoin via software.

Candidate behavior in `noise_firmware/noise_firmware.ino`:

- Enable the Arduino Wi-Fi auto-reconnect policy. Do not call explicit `reconnect()` more often than once per 10 seconds while disconnected; the loop continues to service Noise and rollback logic.
- On re-association, force an immediate fresh authenticated Noise REGISTER. A matching Wi-Fi IP alone never becomes an authenticated registration. Continue normal re-registration every five seconds while connected, so the controller can recover its mapping after an AP reboot even if a disconnect event was missed.
- Keep the existing first-boot rule: an OTA-pending edge must authenticate with its pinned controller within roughly 30 seconds or roll back. A long outage during *first boot* still fails safely instead of claiming an update valid.

`build_reconnect_candidate.sh` compiles and signs **separate edge1/edge2 v9 candidates** under ignored `noise_experiments/edge*_reconnect_v9*`. It neither flashes nor uploads, never overwrites the already prepared v8 presentation files, and scans the actual binaries for all three raw X25519 secrets and legacy HTTP edge strings. Compiled images fit the 1,310,720-byte OTA slot. A v9 candidate must only be installed after a destination has first received and confirmed a valid v8 (or via a carefully reviewed alternate migration); using v9 on a v7 board would make its reserved v8 image permanently unusable there.

**Required proof before claiming auto-rejoin:** keep both edges continuously powered, document initial controller v8/edge v7 or v8 valid/authenticated status, deliberately restart **controller only**, wait 60–90 seconds, and show both edges authenticated again in the same `/status` response without touching edge power. Repeat at least twice. Verify edge version/valid states and no rollback or authentication bypass. If it fails, capture serial logs from the actual edges and distinguish AP re-association from Noise registration failure or power loss. Do not silently merge an untested fix onto `main`.

**Recovery backup:** a 4 MB controller-only full-flash snapshot was read twice in matching 64 KiB chunks, including bootloader/NVS/OTA metadata. Its OTA slot matches the saved signed v8 binary. Located only in ignored, mode-0600 `private_keys/flash_snapshots/full_controller_*/`. It contains an unencrypted private Noise identity; do not distribute, commit or confuse a local snapshot with an independently tested restore. A full snapshot of **each edge** is still absent.
