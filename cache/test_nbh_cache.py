import argparse
import importlib.util
import io
import tempfile
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from unittest import mock
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


H1, H2, DEP = "1" * 32, "2" * 32, "3" * 32
NOW = datetime(2026, 10, 21, tzinfo=timezone.utc)


class FakeCache:
    def __init__(self):
        self.objects, self.bodies = {}, {}

    def put(self, key, body, content_type, at=NOW):
        self.bodies[key] = body
        self.objects[key] = {"Key": key, "ETag": str(hash(body)), "LastModified": at, "Size": len(body)}

    def list(self, prefix=""):
        return {k: dict(o) for k, o in self.objects.items() if k.startswith(prefix)}

    def get(self, key):
        return self.bodies.get(key)

    def delete(self, keys):
        for k in keys:
            self.objects.pop(k, None)
            self.bodies.pop(k, None)

    def path(self, h, refs, at):
        self.put(f"nar/{h}.nar.zst", "nar", "", at)
        refs = " ".join(f"{r}-x" for r in refs)
        self.put(f"{h}.narinfo", f"StorePath: /nix/store/{h}-x\nURL: nar/{h}.nar.zst\nReferences: {refs}\n", "", at)


class Roots(unittest.TestCase):
    def roots(self, links):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for i, target in enumerate(links):
                paths.append(os.path.join(d, f"l{i}"))
                os.symlink(target, paths[-1])
            paths.append(os.path.join(d, "missing"))
            cache = FakeCache()
            with mock.patch.object(nc, "requisites", lambda p: f"{p}\n/nix/store/{DEP}-dep\n"):
                with redirect_stdout(io.StringIO()):
                    nc.cmd_roots(cache, argparse.Namespace(paths=paths))
            return cache

    def test_two_closures_give_two_roots_keyed_by_hash(self):
        cache = self.roots([f"/nix/store/{H1}-system", f"/nix/store/{H2}-system"])
        self.assertEqual(sorted(cache.objects), [f"roots/{H1}", f"roots/{H2}"])
        self.assertIn(f"/nix/store/{DEP}-dep", cache.get(f"roots/{H1}"))

    def test_links_to_one_closure_give_one_root(self):
        cache = self.roots([f"/nix/store/{H1}-system"] * 3)
        self.assertEqual(list(cache.objects), [f"roots/{H1}"])


class Gc(unittest.TestCase):
    def test_drops_a_root_past_the_window_and_keeps_a_fresh_one(self):
        cache, old = FakeCache(), NOW - timedelta(days=40)
        cache.path(H1, [DEP], old)
        cache.path(DEP, [], old)
        cache.path(H2, [], old)
        cache.put(f"roots/{H1}", f"/nix/store/{H1}-x\n", "", NOW - timedelta(days=29))
        cache.put(f"roots/{H2}", f"/nix/store/{H2}-x\n", "", NOW - timedelta(days=31))
        args = argparse.Namespace(stamp=None, min_interval_hours=0, now=NOW.isoformat(), grace_days=14,
                                  roots_days=30, dry_run=False)
        with redirect_stdout(io.StringIO()):
            nc.cmd_gc(cache, args)
        self.assertEqual(sorted(k for k in cache.objects if k.startswith("roots/")), [f"roots/{H1}"])
        self.assertIn(f"{H1}.narinfo", cache.objects)
        self.assertIn(f"{DEP}.narinfo", cache.objects)
        self.assertNotIn(f"{H2}.narinfo", cache.objects)
        self.assertNotIn(f"nar/{H2}.nar.zst", cache.objects)


if __name__ == "__main__":
    unittest.main()
