# Three-ESP32 OTA project

**Current branch: `feature/noise-link`.** The physical boards last reported controller **v8 valid**, edge1 **v7 valid** and edge2 **v7 valid** with authenticated Noise status after manual edge power cycles. Both edges received real Ed25519-signed OTA through controller→edge Noise sessions; controller v7→v8 was signed OTA over **plaintext** laptop HTTP. The prepared *unused* live-demo targets are edge1/edge2 **v8**, controller **v9**. **Do not run or flash any of the historical unsigned v1/v2 instructions below on these boards.** Start with [`OFFLINE_VIVA_GUIDE.md`](OFFLINE_VIVA_GUIDE.md), [`LIVE_DEMO.md`](LIVE_DEMO.md), [`NOISE_RUNTIME_TEST.md`](NOISE_RUNTIME_TEST.md) and [`ABSTRACT_CLAIM_REPORT.md`](ABSTRACT_CLAIM_REPORT.md). Mac-local read-only browser log: [`WEB_LOG.md`](WEB_LOG.md). Mac→controller encryption is only a proposal in [`HOST_LINK_ENCRYPTION_REPORT.md`](HOST_LINK_ENCRYPTION_REPORT.md).

## Historical unsigned v1/v2 transport (not current board state)

The remainder of the old transport tutorial is preserved for reference to `main` only. Its "currently running" version numbers, plaintext edge listeners and commands do **not** describe the current `feature/noise-link` hardware. Do not repeat its v1/v2 flashes or POSTs.

**Historical status:** All six prototype binaries compile for the classic ESP32 with 4 MB flash. Controller v1 was flashed to one working board; controller v2 was then sent over Wi-Fi to `/update`, and `GET /status` independently confirmed `role=0 version=2` after reboot. The Mac automatically left `OTA-CLASS-DEMO` during the reboot, so the original test script falsely reported that confirmation failed; that script has been fixed. A newly purchased second board was detected as ESP32-D0WD-V3 with 4 MB flash and USB-flashed with **edge2 v1**; the upload hash verified. It joined and registered as edge2, responded `role=2 version=1`, accepted edge2 v2 relayed through the controller, rebooted, and independently responded `role=2 version=2`. The teammate's Micro-USB board was flashed with edge1 v1; with all three boards powered, the controller reported `edge1=192.168.4.5 edge2=192.168.4.2`, and direct status checks returned `role=1 version=1` and `role=2 version=2`. Edge1 v2 was then sent **through the controller** to `/edge1`; the edge rebooted and independently returned `role=1 version=2`. **Three-node star OTA transport is now demonstrated on physical boards. Security features are NOT implemented in these images.**

**Security warning:** This version has **no developer signature verification, no downgrade protection, no post-boot rollback confirmation, and no Noise-style authenticated encryption**. A Wi-Fi password is not a substitute. Anyone on the demo Wi-Fi can upload firmware. Use only for short, supervised testing, not as a security demonstration or production device. All firmware images should remain under 1.25 MB using the Arduino ESP32 default 4 MB partition layout (`ota_0`, `ota_1`).

## Hardware / network

- Three classic ESP32 boards, each needing at least 4 MB flash (the controller and edge2 were checked; edge1 is not yet checked). No signal wires between boards.
- Each needs USB power throughout a demonstration; USB data is needed once per board to install v1.
- Controller creates a local Wi-Fi network: **OTA-CLASS-DEMO** / **demo-ota-1234** (example-only password).
- Mac joins that Wi-Fi network to send an image. Joining may temporarily disconnect Mac from its usual internet Wi-Fi; manually reconnect afterward.
- Edges join that network, obtain IPs via DHCP and register their current IP with the controller every 5 seconds.
- Controller: `192.168.4.1` HTTP port 80; edges: their assigned IPs, HTTP port 8080.
- Routes: `GET /status`, `POST /update` for the controller itself, `POST /edge1`, `POST /edge2` for forwarding the original binary to the chosen edge. Edge accepts `POST /update`. Only binary data is transferred; no HTML dashboard is needed.

## Compiling

The code is `ota_prototype.ino`. It is shared by all three boards. The build script sets `NODE_ROLE` to 0 (controller), 1 (edge1), or 2 (edge2), and `FW_VERSION` to 1 or 2. Don't upload an image built for the wrong role. The default Arduino IDE build without these flags is controller v1. Rebuild after changing the sketch:

```bash
cd ~/iot_project_abstracts/ota_prototype
./build_all.sh
```

Ready-to-use `firmware/{controller,edge1,edge2}_v{1,2}/ota_prototype.ino.bin` files are generated alongside bootloader/partition artifacts. All three boards booted v1 and subsequently reported v2 after OTA (controller directly, edges through the controller). These are unsigned proof-of-transport images, not the planned secure release.

## One-board OTA result / repeat test

The working board is currently on **controller v2**, confirmed by querying `/status` after its Wi-Fi update and reboot. USB stayed attached solely for power; firmware was sent over Wi-Fi. The laptop may automatically switch back to its normal internet network when the ESP32 reboots. Rejoin `OTA-CLASS-DEMO` and query `curl --noproxy '*' --max-time 5 http://192.168.4.1/status` before diagnosing a failure.

`./test_controller_ota.sh` now detects v2 and exits without uploading it again. To repeat a real v1-to-v2 OTA, bootstrap controller v1 via USB using `./flash_initial.sh controller /dev/cu.usbserial-...`, rejoin `OTA-CLASS-DEMO`, then run `./test_controller_ota.sh`. USB in the test supplies only power/serial after the one-time v1 bootstrap. Rejoin your normal Wi-Fi afterward.

## Three-board transport demonstration

All three devices are currently running v2. With all boards powered, join `OTA-CLASS-DEMO` and run `curl --noproxy '*' http://192.168.4.1/status` to find the current IPs; check each edge at `http://<edge-ip>:8080/status`. DHCP addresses can change. Edge1 and edge2 v1-to-v2 OTA transfers through the controller have passed. Do **not** re-send an update image merely to repeat a status demonstration. To repeat an actual v1-to-v2 transfer, reflash the *correct role's* v1 initial firmware over USB first, then send its matching v2 image through the controller. Only do this intentionally; old unsigned firmware is not safe against sending an image for the wrong role.

Previously used command for edge1 v1-to-v2, shown for reference **not for rerunning now**:

```bash
cd ~/iot_project_abstracts/ota_prototype
curl --noproxy '*' --fail-with-body --max-time 120 -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @firmware/edge1_v2/ota_prototype.ino.bin http://192.168.4.1/edge1
```

Edge results are reported in HTTP responses and over the controller's USB serial console. Both edge updates have been independently confirmed by querying their status after reboot. To demonstrate current versions, use GET `/status`, not a firmware POST. The controller's `/status` only shows the edge addresses, not their versions.

## Historical note from the unsigned transport branch

The original v1/v2 transport images here have no signature, anti-downgrade, rollback confirmation or Noise encryption. Those improvements were implemented and partly hardware-tested on later branches; see the current-branch links at the top. Do not attribute later results to these historical unsigned images or attribute untested edge rollback to the current boards.
