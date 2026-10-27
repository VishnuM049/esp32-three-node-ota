"""Send an altered full image with a genuine manifest; secure controller v3 must reject it.

Run only on OTA-CLASS-DEMO after the controller shows role=0 version=3.
This writes the *inactive* OTA slot but must NOT activate it or reboot.
"""
from pathlib import Path
import http.client

ROOT = Path(__file__).resolve().parent.parent
HOST = "192.168.4.1"


def status():
    conn = http.client.HTTPConnection(HOST, timeout=8)
    try:
        conn.request("GET", "/status")
        response = conn.getresponse()
        result = response.read().decode("ascii", "replace").strip()
        if response.status != 200:
            raise RuntimeError(f"Status failed: HTTP {response.status}: {result}")
        return result
    finally:
        conn.close()


def main():
    before = status()
    print("Before:", before)
    if "role=0 version=3" not in before:
        raise RuntimeError("Refusing to send: controller is not secure v3")
    image_path = ROOT / "secure_firmware/controller_v4/ota_prototype.ino.bin"
    manifest_path = Path(str(image_path) + ".manifest")
    image = bytearray(image_path.read_bytes())
    manifest = manifest_path.read_bytes()
    if len(manifest) != 109 or len(image) == 0:
        raise RuntimeError("Missing or invalid signed test files")
    image[len(image) // 2] ^= 1  # image no longer matches signed SHA-256
    conn = http.client.HTTPConnection(HOST, timeout=120)
    try:
        conn.request("POST", "/update", body=bytes(image), headers={
            "Content-Type": "application/octet-stream", "X-OTA-Manifest": manifest.hex()})
        response = conn.getresponse()
        body = response.read().decode("ascii", "replace").strip()
        print(f"Upload reply: HTTP {response.status}: {body}")
        if response.status != 403 or "Image SHA-256 does not match" not in body:
            raise RuntimeError("Unexpected result: do not send a valid update until diagnosed")
    finally:
        conn.close()
    after = status()
    print("After:", after)
    if "role=0 version=3" not in after:
        raise RuntimeError("Controller version changed unexpectedly!")
    print("PASS: full tampered firmware rejected and secure controller stayed on v3")


if __name__ == "__main__":
    main()
