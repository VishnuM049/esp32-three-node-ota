#!/usr/bin/env python3
"""Read-only, redundant full-flash snapshot of MAC-pinned controller.

Slow 64 KiB chunks tolerate serial glitches. Output contains private NVS identity;
never upload it or commit it. No erase/write/OTA operation is performed.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
ESP = Path.home() / "Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"
PORT = "/dev/cu.usbserial-110"
MAC = "20:50:0d:1b:64:d8"
SIZE = 0x400000
CHUNK = 0x10000


def call(*arguments: str, timeout: int = 40) -> str:
    proc = subprocess.run([str(ESP), "--chip", "esp32", "--port", PORT, "--baud", "115200", *arguments],
                          text=True, capture_output=True, timeout=timeout, check=False)
    if proc.returncode:
        raise RuntimeError((proc.stdout + proc.stderr)[-350:])
    return proc.stdout


def main():
    os.umask(0o077)
    if not Path(PORT).exists() or not ESP.is_file():
        raise SystemExit("Missing correct USB serial port or local esptool")
    info = call("flash-id")
    if f"MAC:                {MAC}" not in info or "Detected flash size: 4MB" not in info:
        raise SystemExit("STOP: wrong board or flash size")
    folder = ROOT / "private_keys/flash_snapshots" / ("full_controller_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
    folder.mkdir(mode=0o700, parents=True, exist_ok=False)
    print("Reading exact controller", MAC, "into local ignored private folder; no write", flush=True)
    target = folder / "controller_v8_flash_4mb.bin"
    with target.open("xb") as combined:
        target.chmod(0o600)
        for offset in range(0, SIZE, CHUNK):
            left, right = folder / "chunk_A.bin", folder / "chunk_B.bin"
            good = False
            for attempt in range(1, 5):
                left.unlink(missing_ok=True)
                right.unlink(missing_ok=True)
                try:
                    call("read-flash", "--no-progress", hex(offset), hex(CHUNK), str(left))
                    call("read-flash", "--no-progress", hex(offset), hex(CHUNK), str(right))
                    a, b = left.read_bytes(), right.read_bytes()
                    if len(a) != CHUNK or a != b:
                        raise RuntimeError("Chunk reads differ")
                    combined.write(a)
                    good = True
                    break
                except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                    print(f"  retry address {offset:#08x} ({attempt}/4): {str(exc)[-110:]}", flush=True)
            if not good:
                target.unlink(missing_ok=True)
                raise SystemExit("STOP: serial unreliable; NO verified complete backup (partial chunks remain private)")
            print(f"  verified {offset + CHUNK:#08x} / {SIZE:#08x}", flush=True)
            left.unlink(missing_ok=True)
            right.unlink(missing_ok=True)
    data = target.read_bytes()
    identity = (ROOT / "private_keys/noise/controller.x25519").read_bytes()
    if len(data) != SIZE or data[0x1000] != 0xE9 or identity not in data[0x9000:0xE000]:
        target.unlink(missing_ok=True)
        raise SystemExit("STOP: incomplete flash/bootloader/NVS identity; NO verified backup")
    digest = hashlib.sha256(data).hexdigest()
    (folder / "sha256.txt").write_text(f"{digest}  controller_v8_flash_4mb.bin\n")
    print(f"VERIFIED local full 4MB snapshot (2 matching reads per 64KiB): {target}")
    print(f"SHA-256: {digest}")
    print("IMPORTANT: Contains unencrypted private device key. chmod 600; ignored by Git."
          " Encrypt/move this backup securely before relying on it outside this Mac.")


if __name__ == "__main__":
    main()
