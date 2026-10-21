import importlib.util
import os
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("nbh_cache", os.path.join(os.path.dirname(__file__), "nbh-cache.py"))
nc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nc)


class Nix32(unittest.TestCase):
    def test_matches_nix_hash_convert(self):
        sri = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
        self.assertEqual(nc.nar_hash(sri), "sha256:" + KNOWN_EMPTY)

    def test_passes_nix32_through(self):
        self.assertEqual(nc.nar_hash("sha256:" + KNOWN_EMPTY), "sha256:" + KNOWN_EMPTY)


KNOWN_EMPTY = "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73"


class Narinfo(unittest.TestCase):
    def test_round_trip_keeps_empty_references_and_sigs(self):
        f = {"StorePath": "/nix/store/" + "a" * 32 + "-x", "URL": "nar/y.nar.zst", "Compression": "zstd",
             "FileHash": "sha256:f", "FileSize": "1", "NarHash": "sha256:n", "NarSize": "2", "References": "", "Deriver": None}
        text = nc.render_narinfo(f, ["k:s"])
        self.assertIn("References: \n", text)
        self.assertNotIn("Deriver", text)
        self.assertEqual(nc.parse_narinfo(text)["NarSize"], "2")
        self.assertTrue(text.endswith("Sig: k:s\n"))

    def test_fingerprint_sorts_and_prefixes_references(self):
        fp = nc.fingerprint("/nix/store/p", "sha256:h", "5", ["b-y", "a-x"])
        self.assertEqual(fp, "1;/nix/store/p;sha256:h;5;/nix/store/a-x,/nix/store/b-y")


class Sign(unittest.TestCase):
    def test_signature_verifies_under_the_public_half(self):
        import base64
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives import serialization
        k = Ed25519PrivateKey.generate()
        seed = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        pub = k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        secret = "t-1:" + base64.b64encode(seed + pub).decode()
        name, sig = nc.sign(secret, "1;fp").split(":", 1)
        self.assertEqual(name, "t-1")
        k.public_key().verify(base64.b64decode(sig), b"1;fp")


class GcDue(unittest.TestCase):
    def test_missing_stamp_is_due_and_fresh_stamp_is_not(self):
        self.assertTrue(nc.gc_due(None, 24))
        import tempfile
        with tempfile.NamedTemporaryFile() as t:
            self.assertFalse(nc.gc_due(t.name, 24))
            self.assertTrue(nc.gc_due(t.name, 0))


if __name__ == "__main__":
    unittest.main()
