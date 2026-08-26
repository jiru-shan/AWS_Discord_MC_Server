"""RFC 8032 section 7.1 test vectors for the dependency-free Ed25519 verifier."""

import os
import sys
import unittest

# Keep the test run from dropping __pycache__ into lambda/, which would end up
# inside the deployment zip archive_file builds from that directory.
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))

import ed25519_verify  # noqa: E402

# (public key, message, signature), all hex. Straight from RFC 8032 section 7.1.
VECTORS = [
    (
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
        "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
        "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        "af82",
        "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
        "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    ),
    (
        "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b589"
        "09351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
    ),
]


class TestVerify(unittest.TestCase):
    def test_accepts_valid_signatures(self):
        for pk, msg, sig in VECTORS:
            with self.subTest(msg=msg[:16]):
                self.assertTrue(
                    ed25519_verify.verify(
                        bytes.fromhex(pk), bytes.fromhex(sig), bytes.fromhex(msg)
                    )
                )

    def test_rejects_tampered_message(self):
        pk, _, sig = VECTORS[1]
        self.assertFalse(
            ed25519_verify.verify(bytes.fromhex(pk), bytes.fromhex(sig), b"\x73")
        )

    def test_rejects_tampered_signature(self):
        for pk, msg, sig in VECTORS:
            raw = bytearray(bytes.fromhex(sig))
            for index in (0, 31, 32, 63):
                flipped = bytearray(raw)
                flipped[index] ^= 0x01
                with self.subTest(sig=sig[:16], byte=index):
                    self.assertFalse(
                        ed25519_verify.verify(
                            bytes.fromhex(pk), bytes(flipped), bytes.fromhex(msg)
                        )
                    )

    def test_rejects_signature_from_another_key(self):
        pk = VECTORS[0][0]
        _, msg, sig = VECTORS[1]
        self.assertFalse(
            ed25519_verify.verify(
                bytes.fromhex(pk), bytes.fromhex(sig), bytes.fromhex(msg)
            )
        )

    def test_rejects_non_canonical_scalar(self):
        # S must be reduced mod L; S = L is the smallest non-canonical value.
        pk, msg, sig = VECTORS[1]
        raw = bytes.fromhex(sig)
        bad = raw[:32] + ed25519_verify.L.to_bytes(32, "little")
        self.assertFalse(
            ed25519_verify.verify(bytes.fromhex(pk), bad, bytes.fromhex(msg))
        )

    def test_rejects_malformed_input_without_raising(self):
        pk, msg, sig = VECTORS[1]
        self.assertFalse(ed25519_verify.verify(b"", bytes.fromhex(sig), b""))
        self.assertFalse(ed25519_verify.verify(bytes.fromhex(pk), b"\x00" * 63, b""))
        self.assertFalse(ed25519_verify.verify_hex("zz", sig, b""))
        self.assertFalse(ed25519_verify.verify_hex(pk, "not-hex", b""))
        # A y coordinate with no matching x is not a decodable point.
        self.assertFalse(
            ed25519_verify.verify(b"\x02" + b"\x00" * 31, bytes.fromhex(sig), bytes.fromhex(msg))
        )

    def test_verify_hex_matches_verify(self):
        pk, msg, sig = VECTORS[2]
        self.assertTrue(ed25519_verify.verify_hex(pk, sig, bytes.fromhex(msg)))


if __name__ == "__main__":
    unittest.main()
