"""Offline-only identity provisioning tests; no board or network access."""
import json
from pathlib import Path
import stat
import tempfile
import unittest

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization
from noise_keys import ROLES, provision, emit_header


class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / "noise"

    def test_three_unique_keys_match_public_pins_and_are_private(self):
        pins = provision(self.directory)
        self.assertEqual(set(pins), set(ROLES))
        self.assertEqual(len(set(pins.values())), 3)
        self.assertEqual(json.loads((self.directory / "public_pins.json").read_text()), pins)
        for role in ROLES:
            keyfile = self.directory / f"{role}.x25519"
            self.assertEqual(stat.S_IMODE(keyfile.stat().st_mode), 0o600)
            key = X25519PrivateKey.from_private_bytes(keyfile.read_bytes())
            actual = key.public_key().public_bytes(serialization.Encoding.Raw,
                                                    serialization.PublicFormat.Raw).hex()
            self.assertEqual(pins[role], actual)

    def test_refuses_regeneration_or_partial_existing_identity(self):
        pins = provision(self.directory)
        with self.assertRaises(FileExistsError):
            provision(self.directory)
        self.assertEqual(json.loads((self.directory / "public_pins.json").read_text()), pins)
        other = Path(self.tmp.name) / "partial"
        other.mkdir()
        (other / "edge2.x25519").write_bytes(b"old")
        with self.assertRaises(FileExistsError):
            provision(other)
        self.assertFalse((other / "controller.x25519").exists())

    def test_headers_pin_only_correct_peers_and_refuse_overwrite(self):
        pins = provision(self.directory)
        for role in ROLES:
            header = emit_header(self.directory, role)
            text = header.read_text()
            self.assertEqual(stat.S_IMODE(header.stat().st_mode), 0o600)
            self.assertIn(f"#define NOISE_LOCAL_ROLE {ROLES.index(role)}", text)
            for peer in ROLES:
                self.assertEqual(f"NOISE_PINNED_{peer.upper()}" in text,
                                 peer != role and (role == "controller" or peer == "controller"))
            with self.assertRaises(FileExistsError):
                emit_header(self.directory, role)
        self.assertEqual(set(pins), set(ROLES))

    def test_mismatched_role_key_fails_before_header_created(self):
        provision(self.directory)
        (self.directory / "edge1.x25519").write_bytes((self.directory / "edge2.x25519").read_bytes())
        with self.assertRaisesRegex(ValueError, "does not match"):
            emit_header(self.directory, "edge1")
        self.assertFalse((self.directory / "generated/edge1.h").exists())


if __name__ == "__main__":
    unittest.main()
