#!/usr/bin/env python3
"""Local, bounded, read-only ESP32 USB UART diagnostic capture (no reset/flash commands).

Serial port opening may electrically reset the attached ESP32. Run before OTA,
not mid-transfer. Output is private local and ignored by Git.
"""
import argparse
import os
from pathlib import Path
import select
import termios
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=240)
    args = parser.parse_args()
    if not args.port.startswith('/dev/cu.usbserial-') or not 1 <= args.seconds <= 600:
        parser.error('Expected USB serial port and 1..600 seconds')
    os.umask(0o077)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as out:
        out.write(f'UART capture started at {time.strftime("%Y-%m-%d %H:%M:%S %Z")}\n'.encode())
        out.flush()
        fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            settings = termios.tcgetattr(fd)
            settings[0] = 0
            settings[1] = 0
            settings[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB |
                             getattr(termios, 'CRTSCTS', 0))
            settings[2] |= termios.CS8 | termios.CLOCAL | termios.CREAD
            settings[3] = 0
            settings[4] = termios.B115200
            settings[5] = termios.B115200
            termios.tcsetattr(fd, termios.TCSANOW, settings)
            until = time.monotonic() + args.seconds
            while time.monotonic() < until:
                ready, _, _ = select.select([fd], [], [], max(0, min(1, until - time.monotonic())))
                if ready:
                    data = os.read(fd, 4096)
                    if data:
                        out.write(data)
                        out.flush()
        finally:
            os.close(fd)
    print(f'Captured local USB serial to {args.output} (do not publish logs with secrets)')


if __name__ == '__main__':
    main()
