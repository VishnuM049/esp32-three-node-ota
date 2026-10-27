import tempfile
from pathlib import Path
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from manifest import HEADER, MANIFEST_SIZE, sign_image, verify_image


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.image = Path(self.temp.name) / "app.bin"
        self.image.write_bytes(b"example firmware" * 256)
        self.key = Ed25519PrivateKey.generate()
        self.signed = sign_image(self.image, 1, 4, self.key)
        self.pub = self.key.public_key()

    def check(self, data=None, role=1, current=3):
        return verify_image(self.image, self.signed if data is None else data, self.pub, role, current)

    def test_valid(self):
        self.assertEqual(len(self.signed), MANIFEST_SIZE)
        self.assertEqual(self.check(), (1, 4))
        self.assertEqual(HEADER.size, 45)

    def test_modified_image(self):
        self.image.write_bytes(b"X" + self.image.read_bytes()[1:])
        with self.assertRaises(ValueError): self.check()

    def test_wrong_role(self):
        with self.assertRaises(ValueError): self.check(role=2)

    def test_downgrade_or_replay(self):
        with self.assertRaises(ValueError): self.check(current=4)

    def test_changed_signed_version(self):
        forged = bytearray(self.signed)
        forged[5] = 5
        with self.assertRaises(ValueError): self.check(bytes(forged))

    def test_wrong_key(self):
        with self.assertRaises(ValueError):
            verify_image(self.image, self.signed, Ed25519PrivateKey.generate().public_key(), 1, 3)

    def test_truncated_unsigned_and_wrong_format(self):
        for data in (b"", self.signed[:45], self.signed[:-1], b"X" + self.signed[1:]):
            with self.subTest(data=data[:5]), self.assertRaises(ValueError): self.check(data)

    def test_length_mismatch(self):
        self.image.write_bytes(self.image.read_bytes() + b"!")
        with self.assertRaises(ValueError): self.check()


if __name__ == "__main__":
    unittest.main()
