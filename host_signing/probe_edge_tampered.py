"""Send intentionally CORRUPTED signed-v5 image bodies to secure-v4 edges.
No untampered image is transmitted. Requires all boards powered and Mac on OTA-CLASS-DEMO.
Run header-only probe first; do not automatically retry this upload if Wi-Fi switches.
"""
from pathlib import Path
import hashlib
import re
import socket

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from manifest import HEADER, verify_image
from probe_edge_rejections import status

ROOT = Path(__file__).resolve().parent.parent


def test_one(role: int, ip: str):
    before = status(ip, 8080)
    print(f"Before edge{role}: {before}", flush=True)
    if f"role={role} version=4" not in before:
        raise RuntimeError("Target is NOT the intended secure-v4 edge. Refusing upload.")
    path = ROOT / f"rollback_firmware/edge{role}_v5/ota_prototype.ino.bin"
    raw = path.read_bytes()
    signed = Path(str(path) + ".manifest").read_bytes()
    public = Ed25519PublicKey.from_public_bytes((ROOT / "private_keys/demo_public.bin").read_bytes())
    verify_image(path, signed, public, role, 4)
    magic, signed_role, version, length, digest = HEADER.unpack(signed[:HEADER.size])
    if (magic, signed_role, version, length) != (b"OTA1", role, 5, len(raw)):
        raise RuntimeError("Wrong signed firmware metadata")
    corrupted = bytearray(raw)
    corrupted[len(corrupted) // 2] ^= 1  # leave the ESP32 image header intact
    if hashlib.sha256(corrupted).digest() == digest:
        raise RuntimeError("Corruption did not change the signed digest")
    request = (f"POST /update HTTP/1.1\r\nHost: {ip}\r\n"
               f"Content-Type: application/octet-stream\r\nContent-Length: {len(corrupted)}\r\n"
               f"X-OTA-Manifest: {signed.hex()}\r\nConnection: close\r\n\r\n")
    print(f"Sending ONLY tampered edge{role} v5 body ({len(corrupted)} bytes)", flush=True)
    with socket.create_connection((ip, 8080), timeout=8) as conn:
        conn.settimeout(120)
        conn.sendall(request.encode("ascii"))
        conn.sendall(corrupted)
        chunks = []
        while data := conn.recv(2048):
            chunks.append(data)
    response = b"".join(chunks).decode("ascii", "replace")
    expected = "Image SHA-256 does not match signed manifest"
    if not response.startswith("HTTP/1.1 403 ") or expected not in response:
        raise RuntimeError(f"Expected hash rejection; got {response[:260]!r}. Do not retry automatically.")
    print(f"PASS: edge{role} rejected tampered full image by hash", flush=True)
    after = status(ip, 8080)
    if f"role={role} version=4" not in after:
        raise RuntimeError(f"Edge{role} unexpected post-test status: {after}")
    print(f"PASS: edge{role} remains v4", flush=True)


def main():
    controller = status("192.168.4.1", 80)
    print("Controller:", controller, flush=True)
    if "role=0 version=5" not in controller or "ota=valid" not in controller:
        raise RuntimeError("Controller must be confirmed secure v5; refusing test")
    for role in (1, 2):
        match = re.search(rf"edge{role}=([0-9.]+)", controller)
        if not match or match.group(1) == "0.0.0.0":
            raise RuntimeError(f"Edge{role} not registered")
        test_one(role, match.group(1))
    print("PASS: both edges rejected complete tampered signed images without upgrading", flush=True)


if __name__ == "__main__":
    main()
