# Three-ESP32 OTA transport prototype — NOT YET SECURE OTA

**Status (today):** All six binaries compile for the classic ESP32 with 4 MB flash. Controller v1 was flashed to one working board, and its boot message plus AP address were seen on USB serial. Neither a Wi-Fi OTA update nor controller-to-edge transfer has been tested yet. The two remaining boards must be connected and initially flashed before a three-device result can be claimed.

**Security warning:** This version has **no developer signature verification, no downgrade protection, no post-boot rollback confirmation, and no Noise-style authenticated encryption**. A Wi-Fi password is not a substitute. Anyone on the demo Wi-Fi can upload firmware. Use only for short, supervised testing, not as a security demonstration or production device. All firmware images should remain under 1.25 MB using the Arduino ESP32 default 4 MB partition layout (`ota_0`, `ota_1`).

## Hardware / network

- Three classic ESP32 boards, each with at least 4 MB flash (only the first was checked). No signal wires between boards.
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

Ready-to-use `firmware/{controller,edge1,edge2}_v{1,2}/ota_prototype.ino.bin` files are generated alongside bootloader/partition artifacts. The program and roles are compiled, but **only controller v1 has been flashed or boot-tested**.

## One-board test to run next

1. Keep the working board plugged into the Mac for power. Controller v1 has already been installed via USB; do not upload v2 via the Arduino IDE.
2. Connect the Mac's Wi-Fi to `OTA-CLASS-DEMO` (password above). This is the board's own network; it won't provide internet.
3. In a terminal run `~/iot_project_abstracts/ota_prototype/test_controller_ota.sh`. It first fetches `/status` (should be role=0 version=1), POSTs controller v2 over Wi-Fi, waits for reboot, and fetches `/status` again (should be version=2). A failed test means **do not assume OTA works**; collect the script output and debug.
4. Rejoin your regular Wi-Fi after testing. The board can stay plugged into USB; it carries only power/serial during the OTA test.

If this test passes once, rerunning it will show v2 -> v2 (not an actual version change). To repeat, bootstrap controller v1 again via USB using `./flash_initial.sh controller /dev/cu.usbserial-...` (this is a lab test only).

## When the other boards and their data cables arrive

1. Connect one board at a time. Run `ls /dev/cu.usb*` before/after plugging in to find its port. Existing serial ports can change names.
2. Initial flash only: `./flash_initial.sh edge1 /dev/cu.usbserial-...` then, with the next board connected, `./flash_initial.sh edge2 /dev/cu.usbserial-...`. The script checks the chip and its 4 MB flash before writing; respond `YES` only for the board you mean to flash. Boards with another flash size or chip need review first.
3. Supply power to all three boards. Wait about 10 seconds, join the Mac to `OTA-CLASS-DEMO`, then run `curl --noproxy '*' http://192.168.4.1/status` and expect nonzero IP addresses for edge1 and edge2. If they're 0.0.0.0 the edges aren't connected/registered; don't try firmware forwarding yet.
4. Forward each v2 image through the controller, separately, from the Mac:

```bash
cd ~/iot_project_abstracts/ota_prototype
curl --noproxy '*' --fail-with-body --max-time 120 -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @firmware/edge1_v2/ota_prototype.ino.bin http://192.168.4.1/edge1
curl --noproxy '*' --fail-with-body --max-time 120 -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @firmware/edge2_v2/ota_prototype.ino.bin http://192.168.4.1/edge2
```

Edge results are reported in HTTP responses and over the controller's USB serial console. **Forwarding has not been hardware-tested yet.** Confirm actual new versions on each edge through their USB serial output or by querying their IP at `http://<edge-ip>:8080/status` from the Mac. The controller's `/status` only shows the edge addresses, not their versions.

## Next security work (not present here)

The abstract promises Ed25519 signatures on images plus signed role/version metadata, anti-downgrade, rollback recovery, and an authenticated X25519/ChaCha20-Poly1305 channel. Each is additional work and each needs tests; compiling this transport prototype does **not** meet those security claims. Do not submit this code as if it does. Be explicit about completed vs proposed work if time runs out.
