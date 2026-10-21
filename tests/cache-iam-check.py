#!/usr/bin/env python3
import configparser
import json
import sys

import boto3
from botocore.exceptions import ClientError

BUCKET, REGION, SECRETS = "nbh-cache-845087560967", "eu-north-1", "/home/box/secrets"


def client(identity):
    name = f"nbh-cache-{identity}"
    sec = configparser.ConfigParser()
    sec.read(f"{SECRETS}/{name}.credentials")
    return boto3.client("s3", region_name=REGION, aws_access_key_id=sec[name]["aws_access_key_id"],
                        aws_secret_access_key=sec[name]["aws_secret_access_key"])


def attempt(s3, op, **kw):
    try:
        getattr(s3, op)(Bucket=BUCKET, **kw)
        return "allowed"
    except ClientError as e:
        return e.response["Error"]["Code"]


nonce = sys.argv[1]
probe = f"iam-probe-{nonce}"
cases = [
    ("client", "put_object", {"Key": f"nar/{probe}.nar.zst", "Body": b"x"}, "AccessDenied"),
    ("client", "put_object", {"Key": f"{'0' * 32}.narinfo", "Body": b"x"}, "AccessDenied"),
    ("client", "delete_object", {"Key": "nix-cache-info"}, "AccessDenied"),
    ("client", "get_object", {"Key": "nix-cache-info"}, "allowed"),
    ("client", "head_object", {"Key": f"{'0' * 32}.narinfo"}, "404"),
    ("signer", "delete_object", {"Key": "nix-cache-info"}, "AccessDenied"),
    ("signer", "put_object", {"Key": f"nar/{probe}.nar.zst", "Body": b"x"}, "AccessDenied"),
    ("signer", "put_object", {"Key": "roots/DreamingDesk", "Body": b"x"}, "AccessDenied"),
    ("signer", "put_object", {"Key": "roots/x.narinfo", "Body": b"x"}, "AccessDenied"),
    ("signer", "put_object", {"Key": "nix-cache-info", "Body": b"x"}, "AccessDenied"),
    ("signer", "head_object", {"Key": f"{'0' * 32}.narinfo"}, "404"),
    ("gc", "put_object", {"Key": f"nar/{probe}.nar.zst", "Body": b"x"}, "AccessDenied"),
    ("gc", "delete_object", {"Key": "roots/DreamingDesk"}, "AccessDenied"),
    ("gc", "delete_object", {"Key": "nix-cache-info"}, "AccessDenied"),
]
results, ok = [], True
for identity, op, kw, want in cases:
    got = attempt(client(identity), op, **kw)
    results.append({"identity": identity, "op": op, "key": kw["Key"], "want": want, "got": got})
    ok &= got == want
print(json.dumps({"all_as_expected": ok, "cases": results}, indent=1))
sys.exit(0 if ok else 1)
