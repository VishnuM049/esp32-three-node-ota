# Teammate handoff — Micro-USB edge board

You own **edge 1 hardware testing**, not the laptop signing tool or controller code. Read `README.md` first. Firmware is currently a **transport prototype, not secure OTA**.

1. Get a Micro-USB **data** cable, connect your board, and check that a new serial port appears (on macOS: `ls /dev/cu.usb*`). A lit LED alone isn't proof. Report the exact port, flash size, and chip type. If not a classic ESP32 with 4 MB flash, STOP and report before flashing.
2. Once you have ESP32 Arduino support installed, initially USB-flash **edge1 v1** using `./flash_initial.sh edge1 /dev/cu.usbserial-...`. The script asks for confirmation and checks the chip/flash. Never use the edge2 or controller image on this board.
3. Leave the board powered by USB and look at its USB serial output (115200 baud): it should try to join Wi-Fi `OTA-CLASS-DEMO`. It cannot connect until the controller board is powered nearby. Send us its boot output and whether it registers with the controller.
4. Once the controller is available, test `GET http://<edge-IP>:8080/status` and *then* ask before trying edge1 v2 OTA through the controller. See `README.md` for the forwarding command.

**Do not modify** `ota_prototype.ino`, `build_all.sh`, or `firmware/` while we work on signing integration. If you find a firmware bug, send the serial log and proposed fix; we will integrate it in one place. You can put test notes in `docs/edge1-test.md` and commit that file on your own branch.

Nothing is plug-and-play yet: the controller-to-edge relay and Wi-Fi OTA have not been verified on physical hardware. Do not report that the three-node demo works before testing it.
