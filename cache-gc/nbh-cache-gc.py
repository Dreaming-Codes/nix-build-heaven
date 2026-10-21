#!/usr/bin/env python3
import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone

import boto3

HASH = re.compile(r"^[0-9a-df-np-sv-z]{32}$")
STORE_PATH = re.compile(r"/nix/store/([0-9a-df-np-sv-z]{32})-")


def list_objects(s3, bucket):
    objects = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for o in page.get("Contents", []):
            objects[o["Key"]] = o
    return objects


def get_text(s3, bucket, key):
    try:
        return s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode()
    except s3.exceptions.NoSuchKey:
        return None


def parse_narinfo(text):
    fields = dict(line.split(": ", 1) for line in text.splitlines() if ": " in line)
    refs = [r.split("-", 1)[0] for r in fields.get("References", "").split()]
    return fields.get("URL"), refs


def read_roots(s3, bucket, objects):
    roots, etags = set(), {}
    for key, o in objects.items():
        if not key.startswith("roots/"):
            continue
        etags[key] = o["ETag"]
        roots.update(STORE_PATH.findall(get_text(s3, bucket, key) or ""))
    return roots, etags


def mark(s3, bucket, objects, seeds, cache):
    live, stack = set(), [h for h in seeds if f"{h}.narinfo" in objects]
    while stack:
        h = stack.pop()
        if h in live:
            continue
        if h not in cache:
            text = get_text(s3, bucket, f"{h}.narinfo")
            if text is None:
                continue
            cache[h] = parse_narinfo(text)
        live.add(h)
        stack.extend(r for r in cache[h][1] if r not in live and f"{r}.narinfo" in objects)
    return live


def delete(s3, bucket, keys, dry_run):
    keys = sorted(keys)
    if dry_run:
        return
    for i in range(0, len(keys), 1000):
        batch = [{"Key": k} for k in keys[i : i + 1000]]
        res = s3.delete_objects(Bucket=bucket, Delete={"Objects": batch, "Quiet": True})
        if res.get("Errors"):
            sys.exit(f"delete errors: {res['Errors']}")


def main():
    ap = argparse.ArgumentParser(description="Mark and sweep a Nix S3 binary cache from roots/*.")
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--region", required=True)
    ap.add_argument("--endpoint", help="S3-compatible endpoint, e.g. https://<account>.r2.cloudflarestorage.com with --region auto")
    ap.add_argument("--grace", type=int, required=True, help="seconds; anything newer is kept with its closure")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    s3 = boto3.client("s3", region_name=args.region, endpoint_url=args.endpoint)
    started = datetime.now(timezone.utc)
    cutoff = started - timedelta(seconds=args.grace)
    objects = list_objects(s3, args.bucket)
    narinfos = {k[:-8] for k in objects if k.endswith(".narinfo") and HASH.match(k[:-8])}
    recent = {h for h in narinfos if objects[f"{h}.narinfo"]["LastModified"] >= cutoff}

    cache = {}
    roots, etags = read_roots(s3, args.bucket, objects)
    live = mark(s3, args.bucket, objects, roots | recent, cache)

    # A root written while we marked must still protect its closure. Re-read
    # until the root set is stable; Nix only skips uploading paths whose
    # .narinfo exists, so this is the window where a writer can depend on a
    # path we are about to delete.
    for _ in range(5):
        fresh = list_objects(s3, args.bucket)
        _, fresh_etags = read_roots(s3, args.bucket, {k: v for k, v in fresh.items() if k.startswith("roots/")})
        if fresh_etags == etags:
            break
        objects.update(fresh)
        roots, etags = read_roots(s3, args.bucket, fresh)
        newer = {k[:-8] for k, o in fresh.items() if k.endswith(".narinfo") and o["LastModified"] >= cutoff}
        live = mark(s3, args.bucket, objects, roots | recent | newer, cache)
    else:
        sys.exit("roots kept changing; not deleting")

    live = {h for h in live if cache[h][0] in objects}

    dead_narinfos = {f"{h}.narinfo" for h in narinfos - live}
    dead_listings = {f"{h}.ls" for h in narinfos - live if f"{h}.ls" in objects}
    # narinfos go before nars: a crash between the two leaves orphan nars,
    # never a narinfo pointing at a missing nar.
    delete(s3, args.bucket, dead_narinfos | dead_listings, args.dry_run)

    live_nars = {cache[h][0] for h in live if h in cache}
    dead_nars = {
        k for k, o in objects.items()
        if k.startswith("nar/") and k not in live_nars and o["LastModified"] < cutoff
    }
    delete(s3, args.bucket, dead_nars, args.dry_run)

    kept_bytes = sum(o["Size"] for k, o in objects.items() if k not in dead_narinfos | dead_listings | dead_nars)
    print(json.dumps({
        "objects": len(objects),
        "roots": len(roots),
        "narinfos": len(narinfos),
        "live": len(live),
        "recent": len(recent),
        "deleted_narinfos": sorted(dead_narinfos),
        "deleted_nars": len(dead_nars),
        "kept_bytes": kept_bytes,
        "dry_run": args.dry_run,
    }, indent=1))


if __name__ == "__main__":
    main()
