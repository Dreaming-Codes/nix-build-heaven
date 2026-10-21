#!/usr/bin/env python3
import argparse
import base64
import configparser
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3
import zstandard
from botocore.exceptions import ClientError
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HASH = re.compile(r"^[0-9a-df-np-sv-z]{32}$")
STORE_PATH = re.compile(r"/nix/store/([0-9a-df-np-sv-z]{32})-")
NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
WRONG_ACCOUNT = 78


def nix32(raw):
    n = (len(raw) * 8 - 1) // 5 + 1
    out = []
    for i in range(n - 1, -1, -1):
        b = i * 5
        j, k = divmod(b, 8)
        c = raw[j] >> k
        if j + 1 < len(raw):
            c |= raw[j + 1] << (8 - k)
        out.append(NIX32[c & 0x1F])
    return "".join(out)


def nar_hash(value):
    if value.startswith("sha256-"):
        return "sha256:" + nix32(base64.b64decode(value[7:]))
    if value.startswith("sha256:") and len(value) == 59:
        return value
    raise ValueError(f"unsupported NarHash {value}")


def fingerprint(store_path, nar_hash_, nar_size, references):
    refs = ",".join(f"/nix/store/{r}" for r in sorted(references))
    return f"1;{store_path};{nar_hash_};{nar_size};{refs}"


def sign(secret_key, fp):
    name, key = secret_key.strip().split(":", 1)
    seed = base64.b64decode(key)[:32]
    sig = Ed25519PrivateKey.from_private_bytes(seed).sign(fp.encode())
    return f"{name}:{base64.b64encode(sig).decode()}"


def parse_narinfo(text):
    return dict(line.split(": ", 1) for line in text.splitlines() if ": " in line)


def narinfo_refs(fields):
    return [r.split("-", 1)[0] for r in fields.get("References", "").split()]


def render_narinfo(f, sigs):
    keys = ["StorePath", "URL", "Compression", "FileHash", "FileSize", "NarHash", "NarSize", "References", "Deriver", "CA"]
    lines = [f"{k}: {f.get(k) or ''}" for k in keys if k == "References" or f.get(k)]
    return "\n".join(lines + [f"Sig: {s}" for s in sigs]) + "\n"


class Cache:
    def __init__(self, args):
        if args.credentials_file:
            cp = configparser.ConfigParser()
            cp.read(args.credentials_file)
            if args.profile not in cp:
                sys.exit(f"profile {args.profile} not in {args.credentials_file}")
            sec = cp[args.profile]
            session = boto3.session.Session(
                aws_access_key_id=sec["aws_access_key_id"],
                aws_secret_access_key=sec["aws_secret_access_key"],
                region_name=args.region,
            )
        else:
            # A builder has no key of its own; its instance role comes from IMDS.
            session = boto3.session.Session(region_name=args.region)
        account = session.client("sts", region_name=args.region).get_caller_identity()["Account"]
        if account != args.aws_account:
            print(f"credentials belong to account {account}, expected {args.aws_account}", file=sys.stderr)
            sys.exit(WRONG_ACCOUNT)
        self.s3 = session.client("s3", region_name=args.region)
        self.bucket = args.bucket

    def list(self, prefix=""):
        objects = {}
        for page in self.s3.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix=prefix):
            for o in page.get("Contents", []):
                objects[o["Key"]] = o
        return objects

    def get(self, key):
        try:
            return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read().decode()
        except ClientError as e:
            if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
                return None
            raise

    def exists(self, key):
        try:
            self.s3.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return False
            raise

    def put(self, key, body, content_type):
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=body, ContentType=content_type)

    def touch(self, key):
        self.s3.copy_object(
            Bucket=self.bucket, Key=key, CopySource={"Bucket": self.bucket, "Key": key},
            MetadataDirective="REPLACE", ContentType="text/x-nix-narinfo",
        )

    def delete(self, keys):
        keys = sorted(keys)
        for i in range(0, len(keys), 1000):
            res = self.s3.delete_objects(
                Bucket=self.bucket, Delete={"Objects": [{"Key": k} for k in keys[i : i + 1000]], "Quiet": True}
            )
            if res.get("Errors"):
                sys.exit(f"delete errors: {res['Errors']}")


def path_infos(paths, recursive):
    cmd = ["nix", "path-info", "--json"] + (["--recursive"] if recursive else []) + list(paths)
    data = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)
    if isinstance(data, list):
        data = {d["path"]: d for d in data}
    infos = {}
    for path, d in data.items():
        if d is None:
            sys.exit(f"{path} is not valid in the local store")
        path = path if path.startswith("/nix/store/") else f"/nix/store/{path}"
        infos[path] = {
            "narHash": nar_hash(d["narHash"]),
            "narSize": d["narSize"],
            "references": sorted(os.path.basename(r) for r in d.get("references", [])),
            "deriver": os.path.basename(d["deriver"]) if d.get("deriver") else None,
            "ca": d.get("ca"),
        }
    return infos


def upstream_has(h, upstream):
    for url in upstream:
        req = urllib.request.Request(f"{url}/{h}.narinfo", method="HEAD")
        for _ in range(3):
            try:
                with urllib.request.urlopen(req, timeout=20):
                    return url
            except urllib.error.HTTPError as e:
                if e.code in (403, 404, 410):
                    break
            except OSError:
                continue
        else:
            sys.exit(f"{url} did not answer for {h}")
    return None


def refs_first(infos):
    order, seen = [], set()

    def visit(p):
        if p in seen:
            return
        seen.add(p)
        for r in infos[p]["references"]:
            rp = f"/nix/store/{r}"
            if rp in infos and rp != p:
                visit(rp)
        order.append(p)

    sys.setrecursionlimit(100000)
    for p in sorted(infos):
        visit(p)
    return order


def cmd_push(cache, args):
    infos = path_infos(args.paths, recursive=True)
    report = {"closure": len(infos), "upstream": 0, "refreshed": [], "uploaded": [], "bytes": 0}
    for path in refs_first(infos):
        h = os.path.basename(path)[:32]
        if upstream_has(h, args.upstream):
            report["upstream"] += 1
            continue
        if cache.exists(f"{h}.narinfo"):
            cache.touch(f"{h}.narinfo")
            report["refreshed"].append(path)
            continue
        info = infos[path]
        with tempfile.NamedTemporaryFile(dir=args.tmpdir) as tmp:
            dump = subprocess.Popen(["nix-store", "--dump", path], stdout=subprocess.PIPE)
            digest, size = hashlib.sha256(), 0
            with zstandard.ZstdCompressor(level=args.level, threads=-1).stream_writer(tmp, closefd=False) as w:
                for chunk in iter(lambda: dump.stdout.read(1 << 20), b""):
                    w.write(chunk)
            if dump.wait() != 0:
                sys.exit(f"nix-store --dump {path} failed")
            tmp.flush()
            tmp.seek(0)
            for chunk in iter(lambda: tmp.read(1 << 20), b""):
                digest.update(chunk)
                size += len(chunk)
            file_hash = nix32(digest.digest())
            nar_key = f"nar/{file_hash}.nar.zst"
            if not cache.exists(nar_key):
                cache.s3.upload_file(tmp.name, cache.bucket, nar_key, ExtraArgs={"ContentType": "application/x-nix-nar"})
        fields = {
            "StorePath": path, "URL": nar_key, "Compression": "zstd",
            "FileHash": f"sha256:{file_hash}", "FileSize": str(size),
            "NarHash": info["narHash"], "NarSize": str(info["narSize"]),
            "References": " ".join(info["references"]), "Deriver": info["deriver"], "CA": info["ca"],
        }
        cache.put(f"{h}.narinfo", render_narinfo(fields, []), "text/x-nix-narinfo")
        report["uploaded"].append(path)
        report["bytes"] += size
    print(json.dumps(report, indent=1))


def verify_nar(cache, fields):
    body = cache.s3.get_object(Bucket=cache.bucket, Key=fields["URL"])["Body"]
    if fields.get("Compression") != "zstd":
        return False, f"compression {fields.get('Compression')}"
    digest, size = hashlib.sha256(), 0
    with zstandard.ZstdDecompressor().stream_reader(body) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    got = "sha256:" + nix32(digest.digest())
    if got != fields["NarHash"] or str(size) != fields["NarSize"]:
        return False, f"nar is {got} {size}, narinfo says {fields['NarHash']} {fields['NarSize']}"
    return True, "ok"


def cmd_sign(cache, args):
    secret = open(args.secret_key_file).read()
    key_name = secret.split(":", 1)[0]
    expected = {l.strip() for l in open(args.expect) if l.strip()}
    report = {"signed": [], "already": 0, "unexpected": [], "rejected": {}}
    for key in sorted(k for k in cache.list() if k.endswith(".narinfo") and HASH.match(k[:-8])):
        text = cache.get(key)
        if text is None:
            continue
        sigs = [l[5:] for l in text.splitlines() if l.startswith("Sig: ")]
        fields = parse_narinfo(text)
        if any(s.startswith(key_name + ":") for s in sigs):
            report["already"] += 1
            continue
        if fields["StorePath"] not in expected:
            report["unexpected"].append(fields["StorePath"])
            continue
        ok, why = verify_nar(cache, fields)
        if not ok:
            report["rejected"][fields["StorePath"]] = why
            continue
        fp = fingerprint(fields["StorePath"], fields["NarHash"], fields["NarSize"], fields.get("References", "").split())
        cache.put(key, render_narinfo(fields, sigs + [sign(secret, fp)]), "text/x-nix-narinfo")
        report["signed"].append(fields["StorePath"])
    print(json.dumps(report, indent=1))


def requisites(path):
    return subprocess.run(["nix-store", "--query", "--requisites", path], check=True, capture_output=True, text=True).stdout


def cmd_roots(cache, args):
    # Keyed by the store hash, so one closure is one root wherever it runs.
    # Every run rewrites it, which keeps LastModified inside the roots window.
    stores = sorted({os.path.realpath(p) for p in args.paths if os.path.lexists(p)})
    written = {}
    for path in stores:
        m = STORE_PATH.match(path)
        if not m:
            sys.exit(f"{path} is not a store path")
        closure = requisites(path)
        cache.put(f"roots/{m.group(1)}", closure, "text/plain")
        written[f"roots/{m.group(1)}"] = len(closure.split())
    print(json.dumps(written))


def read_roots(cache, objects, cutoff):
    roots, seen, expired = set(), {}, set()
    for key, o in objects.items():
        if not key.startswith("roots/"):
            continue
        if o["LastModified"] < cutoff:
            expired.add(key)
            continue
        seen[key] = (o["ETag"], o["LastModified"])
        roots.update(STORE_PATH.findall(cache.get(key) or ""))
    return roots, seen, expired


def mark(cache, objects, seeds, narinfos):
    live, stack = set(), [h for h in seeds if f"{h}.narinfo" in objects]
    while stack:
        h = stack.pop()
        if h in live:
            continue
        if h not in narinfos:
            text = cache.get(f"{h}.narinfo")
            if text is None:
                continue
            narinfos[h] = parse_narinfo(text)
        live.add(h)
        stack.extend(r for r in narinfo_refs(narinfos[h]) if r not in live and f"{r}.narinfo" in objects)
    return live


def gc_due(stamp, min_interval_hours):
    if not stamp or not os.path.exists(stamp):
        return True
    age = datetime.now(timezone.utc).timestamp() - os.path.getmtime(stamp)
    return age >= min_interval_hours * 3600


def cmd_gc(cache, args):
    if not gc_due(args.stamp, args.min_interval_hours):
        print(json.dumps({"skipped": f"last run under {args.min_interval_hours} h ago", "stamp": args.stamp}))
        return
    now = datetime.fromisoformat(args.now) if args.now else datetime.now(timezone.utc)
    cutoff = now - timedelta(days=args.grace_days)
    roots_cutoff = now - timedelta(days=args.roots_days)
    objects = cache.list()
    hashes = {k[:-8] for k in objects if k.endswith(".narinfo") and HASH.match(k[:-8])}
    recent = {h for h in hashes if objects[f"{h}.narinfo"]["LastModified"] >= cutoff}
    narinfos = {}
    roots, seen, expired = read_roots(cache, objects, roots_cutoff)
    live = mark(cache, objects, roots | recent, narinfos)

    for _ in range(5):
        fresh = cache.list("roots/")
        if {k: (o["ETag"], o["LastModified"]) for k, o in fresh.items() if o["LastModified"] >= roots_cutoff} == seen:
            break
        fresh = cache.list()
        objects.update(fresh)
        roots, seen, expired = read_roots(cache, fresh, roots_cutoff)
        newer = {k[:-8] for k, o in fresh.items() if k.endswith(".narinfo") and HASH.match(k[:-8]) and o["LastModified"] >= cutoff}
        live = mark(cache, objects, roots | recent | newer, narinfos)
    else:
        sys.exit("roots kept changing; not deleting")

    live = {h for h in live if narinfos[h].get("URL") in objects}
    dead_narinfos = {f"{h}.narinfo" for h in hashes - live}
    dead_listings = {f"{h}.ls" for h in hashes - live if f"{h}.ls" in objects}
    live_nars = {narinfos[h]["URL"] for h in live}
    dead_nars = {k for k, o in objects.items() if k.startswith("nar/") and k not in live_nars and o["LastModified"] < cutoff}
    if not args.dry_run:
        cache.delete(dead_narinfos | dead_listings)
        cache.delete(dead_nars)
        cache.delete(expired)
        if args.stamp:
            os.makedirs(os.path.dirname(args.stamp) or ".", exist_ok=True)
            open(args.stamp, "w").close()
    gone = dead_narinfos | dead_listings | dead_nars
    print(json.dumps({
        "now": now.isoformat(), "grace_days": args.grace_days, "objects": len(objects), "roots": len(roots),
        "narinfos": len(hashes), "live": len(live), "recent": len(recent),
        "roots_days": args.roots_days, "deleted_roots": sorted(expired),
        "deleted_narinfos": sorted(dead_narinfos), "deleted_nars": sorted(dead_nars),
        "kept_bytes": sum(o["Size"] for k, o in objects.items() if k not in gone), "dry_run": args.dry_run,
    }, indent=1))


def main():
    ap = argparse.ArgumentParser(description="Push to, sign, root and sweep the Nix Build Heaven S3 binary cache.")
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--region", required=True)
    ap.add_argument("--aws-account", required=True, help="12-digit account the key must belong to; exit 78 otherwise")
    ap.add_argument("--credentials-file", help="AWS shared credentials file; AWS_* env and ~/.aws are ignored. Omit to use the default chain, as a builder does for its instance role")
    ap.add_argument("--profile")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("push", help="upload unsigned the closure paths no upstream cache serves")
    p.add_argument("--upstream", action="append", required=True)
    p.add_argument("--level", type=int, default=12)
    p.add_argument("--tmpdir", default=None)
    p.add_argument("paths", nargs="+")

    p = sub.add_parser("sign", help="sign narinfos of expected paths whose nar matches NarHash")
    p.add_argument("--secret-key-file", required=True)
    p.add_argument("--expect", required=True, help="file of store paths allowed to be signed, one per line")

    p = sub.add_parser("roots", help="write roots/HASH with the closure of each store path PATHS resolve to")
    p.add_argument("paths", nargs="+")

    p = sub.add_parser("gc", help="mark from roots/* newer than the roots window and narinfos newer than the grace window, sweep the rest")
    p.add_argument("--grace-days", type=float, default=14)
    p.add_argument("--roots-days", type=float, default=30, help="a root not rewritten for this long is deleted")
    p.add_argument("--now", help="ISO 8601 clock override, for tests")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--stamp", help="file touched after a real run")
    p.add_argument("--min-interval-hours", type=float, default=0)

    args = ap.parse_args()
    if not re.fullmatch(r"[0-9]{12}", args.aws_account):
        ap.error("--aws-account must be 12 digits")
    if bool(args.credentials_file) != bool(args.profile):
        ap.error("--credentials-file and --profile go together")
    cache = Cache(args)
    {"push": cmd_push, "sign": cmd_sign, "roots": cmd_roots, "gc": cmd_gc}[args.cmd](cache, args)


if __name__ == "__main__":
    main()
