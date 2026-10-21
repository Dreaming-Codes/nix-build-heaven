#!/usr/bin/env python3
"""Monthly cost of the shared Nix cache on S3 eu-north-1, Cloudflare R2, or both.

Prices were read on 2026-10-21 from the AWS Price List API (AmazonS3 and
AWSDataTransfer, regionCode eu-north-1) and https://developers.cloudflare.com/r2/pricing/.
"""
import argparse
import json
import math

S3_STORAGE_GB = 0.023
S3_PUT_LIST_PER_1K = 0.005
S3_GET_PER_1K = 0.0004
AWS_DTO_PER_GB = 0.09
AWS_DTO_FREE_GB = 100

R2_STORAGE_GB = 0.015
R2_CLASS_A_PER_M = 4.50
R2_CLASS_B_PER_M = 0.36
R2_FREE_STORAGE_GB = 10
R2_FREE_CLASS_A = 1_000_000
R2_FREE_CLASS_B = 10_000_000

WEEKS = 52 / 12

# From tests/results/cache-proto/sizes.json: weekly `nix flake update` of /workspace/nbh/nixos,
# lock aa2135b (nixpkgs 91a5f61, 2026-10-09) against cfc5996 (8d71b6f, 2026-10-15), both hosts.
BUILT_NOW_GB = 4.10
BUILT_WEEK_GB = 1.96
PULL_BUILT_WEEK_GB = 1.11 + 1.07
UPSTREAM_NOW_GB = 23.98
UPSTREAM_WEEK_GB = 12.43
PULL_UPSTREAM_WEEK_GB = 4.82 + 10.26
NEW_PATHS_WEEK = 272 + 373
COPYBACK_WEEK_GB = 3.45
KERNEL_BUMP_PUSH_GB = 0.45
KERNEL_BUMP_PULL_GB = 2 * 0.19


def scenario(cache_gb, push_gb, pull_gb, paths_week, gets):
    return dict(cache_gb=cache_gb, builder_push_gb=push_gb, machine_pull_gb=pull_gb, builder_pull_gb=0,
                ssh_copyback_gb=COPYBACK_WEEK_GB * WEEKS, other_aws_dto_gb=0,
                puts=int(2 * paths_week * WEEKS), gets=gets, lists=60)


SCENARIOS = {
    "A built only": scenario(BUILT_NOW_GB + BUILT_WEEK_GB, BUILT_WEEK_GB * WEEKS,
                             PULL_BUILT_WEEK_GB * WEEKS, 272, 210_000),
    "A + 4 kernel bumps": scenario(BUILT_NOW_GB + BUILT_WEEK_GB + KERNEL_BUMP_PUSH_GB,
                                   BUILT_WEEK_GB * WEEKS + 4 * KERNEL_BUMP_PUSH_GB,
                                   PULL_BUILT_WEEK_GB * WEEKS + 4 * KERNEL_BUMP_PULL_GB, 280, 210_000),
    "B full closure": scenario(BUILT_NOW_GB + UPSTREAM_NOW_GB + BUILT_WEEK_GB + UPSTREAM_WEEK_GB,
                               (BUILT_WEEK_GB + UPSTREAM_WEEK_GB) * WEEKS,
                               (PULL_BUILT_WEEK_GB + PULL_UPSTREAM_WEEK_GB) * WEEKS, NEW_PATHS_WEEK, 250_000),
}
SCENARIOS["B, 100 GB free egress used elsewhere"] = dict(SCENARIOS["B full closure"], other_aws_dto_gb=100)


def aws_dto(gb, other):
    """The 100 GB free tier is shared with every other AWS egress on the account."""
    billable = max(0.0, gb + other - AWS_DTO_FREE_GB) - max(0.0, other - AWS_DTO_FREE_GB)
    return billable * AWS_DTO_PER_GB


def r2_billed(used, free, unit):
    return math.ceil(max(0, used - free) / unit) if used > free else 0


def s3_ops(puts, gets, lists):
    return (puts + lists) / 1000 * S3_PUT_LIST_PER_1K + gets / 1000 * S3_GET_PER_1K


def r2_ops(class_a, class_b):
    return (r2_billed(class_a, R2_FREE_CLASS_A, 1_000_000) * R2_CLASS_A_PER_M
            + r2_billed(class_b, R2_FREE_CLASS_B, 1_000_000) * R2_CLASS_B_PER_M)


def r2_storage(gb):
    return r2_billed(gb, R2_FREE_STORAGE_GB, 1) * R2_STORAGE_GB


def model(s):
    o = s["other_aws_dto_gb"]
    base_dto = s["ssh_copyback_gb"]
    out = {}

    dto = aws_dto(base_dto + s["machine_pull_gb"], o)
    out["S3 only"] = dict(storage=s["cache_gb"] * S3_STORAGE_GB, ops=s3_ops(s["puts"], s["gets"], s["lists"]), dto=dto)

    dto = aws_dto(base_dto + s["builder_push_gb"], o)
    out["R2 only"] = dict(storage=r2_storage(s["cache_gb"]), ops=r2_ops(s["puts"] + s["lists"], s["gets"]), dto=dto)

    # Builders write and read S3 in-region; a mirror copies each new object to
    # R2 once, so the internet leg is paid per GB pushed, not per machine pull.
    dto = aws_dto(base_dto + s["builder_push_gb"], o)
    out["S3 + R2 mirror"] = dict(
        storage=s["cache_gb"] * S3_STORAGE_GB + r2_storage(s["cache_gb"]),
        ops=s3_ops(s["puts"], s["gets"] // 2 + s["puts"], s["lists"]) + r2_ops(s["puts"] + s["lists"], s["gets"] // 2),
        dto=dto,
    )
    for v in out.values():
        v["total"] = round(sum(v.values()), 3)
        for k in ("storage", "ops", "dto"):
            v[k] = round(v[k], 3)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    results = {name: {"inputs": s, "cost": model(s)} for name, s in SCENARIOS.items()}
    if args.json:
        print(json.dumps(results, indent=1))
        return
    print(f"{'scenario':<18} {'design':<16} {'storage':>8} {'ops':>7} {'aws dto':>8} {'total':>8}")
    for name, r in results.items():
        for design, c in r["cost"].items():
            print(f"{name:<18} {design:<16} {c['storage']:>8.3f} {c['ops']:>7.3f} {c['dto']:>8.3f} {c['total']:>8.3f}")


if __name__ == "__main__":
    main()
