# Three-ESP32 OTA transport prototype — NOT YET SECURE OTA

**Status:** All six prototype binaries compile for the classic ESP32 with 4 MB flash. Controller v1 was flashed to one working board; controller v2 was then sent over Wi-Fi to `/update`, and `GET /status` independently confirmed `role=0 version=2` after reboot. The Mac automatically left `OTA-CLASS-DEMO` during the reboot, so the original test script falsely reported that confirmation failed; that script has been fixed. A newly purchased second board was detected as ESP32-D0WD-V3 with 4 MB flash and USB-flashed with **edge2 v1**; the upload hash verified. It joined and registered as edge2, responded `role=2 version=1`, accepted edge2 v2 relayed through the controller, rebooted, and independently responded `role=2 version=2`. **Two-board controller-to-edge OTA transport is proven.** The teammate's Micro-USB edge1 board must still be tested and initially flashed before a three-device result can be claimed.

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

Ready-to-use `firmware/{controller,edge1,edge2}_v{1,2}/ota_prototype.ino.bin` files are generated alongside bootloader/partition artifacts. Controller and edge2 both booted v1 and then v2 by OTA. Edge1 is compiled but **has not been hardware-tested**.

## One-board OTA result / repeat test

The working board is currently on **controller v2**, confirmed by querying `/status` after its Wi-Fi update and reboot. USB stayed attached solely for power; firmware was sent over Wi-Fi. The laptop may automatically switch back to its normal internet network when the ESP32 reboots. Rejoin `OTA-CLASS-DEMO` and query `curl --noproxy '*' --max-time 5 http://192.168.4.1/status` before diagnosing a failure.

`./test_controller_ota.sh` now detects v2 and exits without uploading it again. To repeat a real v1-to-v2 OTA, bootstrap controller v1 via USB using `./flash_initial.sh controller /dev/cu.usbserial-...`, rejoin `OTA-CLASS-DEMO`, then run `./test_controller_ota.sh`. USB in the test supplies only power/serial after the one-time v1 bootstrap. Rejoin your normal Wi-Fi afterward.

## When the remaining edge1 board and its data cable arrive

1. Edge2 is already running v2 on the newly purchased board. Do not reflash it unless recovery is necessary. Connect remaining unflashed boards one at a time. Run `ls /dev/cu.usb*` before/after plugging in to find their port. Existing serial ports can change names.
2. Teammate's Micro-USB board still needs an initial flash: `./flash_initial.sh edge1 /dev/cu.usbserial-...`. The script checks the chip and its 4 MB flash before writing; respond `YES` only for the board you mean to flash. Boards with another flash size or chip need review first.
3. Supply power to all three boards. Wait about 10 seconds, join the Mac to `OTA-CLASS-DEMO`, then run `curl --noproxy '*' http://192.168.4.1/status` and expect nonzero IP addresses for edge1 and edge2. If they're 0.0.0.0 the edges aren't connected/registered; don't try firmware forwarding yet.
4. Edge2's v1-to-v2 OTA through the controller has already passed. After edge1 is connected and verified as v1, send **only edge1 v2** through the controller:

```bash
cd ~/iot_project_abstracts/ota_prototype
curl --noproxy '*' --fail-with-body --max-time 120 -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @firmware/edge1_v2/ota_prototype.ino.bin http://192.168.4.1/edge1
```

Edge results are reported in HTTP responses and over the controller's USB serial console. Forwarding to **edge2** has been hardware-tested; **edge1 has not**. Confirm edge1's new version via USB serial or by querying its IP at `http://<edge-ip>:8080/status` from the Mac. The controller's `/status` only shows the edge addresses, not their versions.

## Next security work (not present here)

The abstract promises Ed25519 signatures on images plus signed role/version metadata, anti-downgrade, rollback recovery, and an authenticated X25519/ChaCha20-Poly1305 channel. Each is additional work and each needs tests; compiling this transport prototype does **not** meet those security claims. Do not submit this code as if it does. Be explicit about completed vs proposed work if time runs out.
