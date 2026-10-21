# Shared binary cache, phase 1

Status: design and prototype only. Nothing here is wired into `modules/` or `infra/`.

Goal, in Lorenzo's words: "a shared nix build cache that can be used both my machines and the builders. We need the cache to not blow in size so we should only keep what is used in the flake currently, if there's no proper way to do this we can probably do a time retention period".

Who notices. DreamingDesk and DreamingBlade stop rebuilding what the other host or a builder already built, and a builder stops rebuilding its own last outputs. The next maintainer inherits one bucket, one signing key, a root-file convention and one GC command.

Labels. (measured) means seen this session. (read) means taken from a doc or source file listed under Sources. (inferred) follows from those. (guess) is a prediction.

## Comparison

Prices: S3 Standard eu-north-1 $0.023/GB-month, PUT and LIST $0.005 per 1k, GET $0.0004 per 1k, internet egress $0.09/GB after 100 GB/month free across the whole AWS account (read, AWS Price List API and the S3 pricing page). S3 to EC2 in the same region is free (read, S3 pricing page). R2 Standard $0.015/GB-month, Class A $4.50/M, Class B $0.36/M, egress free, free tier 10 GB-month, 1M A, 10M B, deletes free (read, R2 pricing page). EC2 to the internet, which includes EC2 to R2, is the same $0.09/GB AWS egress line (read, Price List API `EUN1-DataTransfer-Out-Bytes`).

| Design | Who writes | Who reads | GC | Always on | ~50 GB/month | His machines' egress |
| --- | --- | --- | --- | --- | --- | --- |
| Plain S3 bucket, `s3://` store | Builders in-region for free (instance profile or gate-minted session creds), or hosts with `nix copy` | Builders free in-region, hosts over the internet | None built in. Bring your own (this doc) | Nothing | $1.15 storage + cents of requests (inferred) | $0.09/GB after the shared 100 GB free (read) |
| Plain R2 bucket, `s3://…?endpoint=…&region=auto` | Builders pay AWS egress $0.09/GB to push (read). Hosts push free | Everyone, egress free (read) | Same bring-your-own GC. R2 lifecycle exists but is age-based | Nothing | $0.60 (50 GB minus 10 free, inferred) | $0 (read) |
| niks3 (Mic92) on S3 or R2 | `niks3 push` asks the server for presigned URLs, then PUTs to the bucket (read) | Straight from the bucket (read) | Closures older than `--older-than` (default 720h) and not pinned are dropped, reachability walked in Postgres, orphans marked then deleted after a grace period (read, `server/pg/query.sql`, `cmd/niks3/main.go`) | niks3 server plus PostgreSQL (read) | Bucket cost plus a host for the server (guess: $4+/month for the smallest VM) | Same as the bucket under it |
| Attic | `attic push` to atticd, which chunks and dedups (read) | Through atticd, which signs on the fly (read) | Time-based retention per cache, run every 12 h by default, LRU by access (read, `config-template.toml`, README) | atticd plus a DB (read) | Bucket cost plus a host (guess, as niks3) | Through the server, so the server's egress |
| Cachix | `cachix push` | cachix.org CDN | LRU eviction once the storage limit is hit (read, pricing FAQ) | Hosted | Starter plan is 50 GiB, price is "contact" on the page today (read) | Unlimited bandwidth (read) |
| S3 or R2 lifecycle expiry only | Anyone | Anyone | Deletes by object age, not last use (read, S3 lifecycle doc) | Nothing | Bucket cost | Bucket rate |

Why lifecycle alone is wrong here. Expiry counts from object creation (read). Nix never re-uploads a path whose `.narinfo` exists (read, `binary-cache-store.cc` `isValidPathUncached` and `uploadData` skip), so glibc for the running system expires on day N while it is still in use (inferred). Expiry also deletes `.narinfo` and `nar/` independently, so a live narinfo can point at a deleted nar, or a path can lose a reference (inferred). A bucket policy cannot stop a lifecycle delete (read).

## Recommendation

A plain bucket plus our own root-based mark and sweep, run by the gate. No server.

Bucket. R2, if a Cloudflare account and one more credential are acceptable. Otherwise S3 in eu-north-1. R2 wins on every modelled scenario (see Costs) because storage is 35% cheaper and the first 10 GB are free. AWS egress is identical in both: with S3 the hosts pay it on pull, with R2 the builders pay it on push, and in this setup one host pulls about what a builder pushes (inferred). The "S3 for builders plus R2 mirror for hosts" hybrid is always the most expensive since it stores everything twice (inferred from the model).

Why not niks3 or Attic. Both do the right GC, niks3 almost exactly the root model below with "pins", but both need an always-on server and a database, which this project rules out (read for the requirement, inferred for the fit). niks3 stays the fallback if the root files below turn out too fragile.

Signing. The key stays on Lorenzo's machine. Builders upload unsigned. After copy-back the client signs only the narinfos whose NarHash matches its own copy, with `nix store sign --store <cache>` (measured to work against S3, see Prototype). A builder never holds a long-lived key, which matters because fixed-output derivations get network access and can reach IMDS user-data (inferred).

Writes. Builders push in their session with `post-build-hook` or a `nix copy` at session end, using credentials minted by the gate per launch. On S3 that is a session policy or instance profile with PutObject and GetObject but no DeleteObject. On R2 it is a temporary credential signed locally by the gate with `actions` that omit DeleteObject and a short `ttlSeconds` (read, R2 temporary credentials doc). Only the gate's GC deletes.

## Roots and GC

Roots. One small object per thing to keep, `roots/<name>`, holding store paths one per line. GC treats every listed path as live and walks `References:` from it, so a root may list just a toplevel or a full `nix path-info -r` closure. The full closure is safer: it keeps a host's paths even if its toplevel itself was never pushed (inferred).

- `roots/DreamingDesk` and `roots/DreamingBlade` are rewritten on every switch from an activation hook or a small unit, from `/run/current-system`. Adding `/run/booted-system` to the same file keeps the reboot target. Old generations are not roots, which is the "only what the flake uses currently" rule.
- `roots/builder-ami` is written by `upload-ami.sh` only if builders ever substitute their own image paths. The AMI itself is an EBS snapshot and does not need the cache.
- The gate writes `roots/session-<id>` before a session pushes and deletes it after the host has switched or after the grace window, whichever is first.

Algorithm (prototype `cache-gc/nbh-cache-gc.py`).

1. Note the start time T. List every object with its LastModified.
2. Seeds are every hash named in `roots/*` plus every narinfo newer than T minus grace.
3. Walk `References:` of each seed narinfo. Everything reached is live, so a recent path keeps its whole closure, not just itself.
4. Re-list `roots/*`. If any ETag changed, add the new roots and walk again. Give up and delete nothing if roots keep changing.
5. Drop from live any narinfo whose nar is missing. It is already broken and Nix treats a missing nar as never there.
6. Delete dead `.narinfo` and their `.ls` first.
7. Delete `nar/*` that no live narinfo names and that are older than the grace window. Nars are keyed by compressed-file hash, so two narinfos can share one (read, `uploadData`), which is why nars are swept by reference and never per dead narinfo.

Idempotent. A second run over the same roots deletes nothing (measured). Deleting a key that is already gone is not an error in S3 DeleteObjects (inferred from the API, and run 2 issued no deletes anyway).

Crash and race cases.

| Case | Result |
| --- | --- |
| Writer crashes after the nar, before the narinfo | Nix writes the nar first and the narinfo last (read, `uploadData`, `uploadNarInfo`). The orphan nar is swept after grace |
| Half-written narinfo | S3 and R2 PUTs are atomic objects, so a reader sees the old state or the whole new one (inferred from their consistency docs) |
| GC crashes between steps 6 and 7 | Narinfos go first, so the worst state is orphan nars, swept next run |
| Live narinfo, deleted nar | Only from an outside actor or the race below. Step 5 drops that narinfo next run. Clients get a missing-nar error, which upstream Nix treats as SubstituteGone and falls through to the next substituter or a build (read, `substitution-goal.cc`). Determinate Nix 2.35 is assumed to carry this (guess, not tested) |
| Writer skips path X because its narinfo exists, then GC deletes X | The real window. Nix checks references at narinfo write but from its in-memory cache (read, `uploadNarInfo`), so it can miss this. Grace covers X only if X is recent. Closing it needs the root written before the push (the writer protocol below) and GC re-reading roots before delete (step 4). The leftover window is the seconds between step 4 and the delete call. The damage is an incomplete closure, which Nix resolves by building or substituting X elsewhere (inferred) |
| Writer skips a nar upload because the nar exists, then GC deletes it | Same window, same fix, then step 5 repairs it on the next run |
| Stale positive narinfo cache on a host | `narinfo-cache-positive-ttl` defaults to 30 days (measured, `nix config show`), so a host may believe a swept path exists. Same SubstituteGone path as above |

Writer protocol. Write or refresh the root, push, then re-check that every path in the pushed closure has a narinfo and re-push any that are missing. `nix copy` is idempotent, so the re-check is just a second `nix copy --to`.

Where GC runs. In the gate after a session ends, at most once per 24 h, plus a manual `nbh-cache gc`. No Lambda and no builder involvement. Cost per run at 50 GB, about 20k objects (guess): 20 LISTs and narinfo GETs only for hashes not already in a local cache, since narinfos only change by gaining signatures. That is well under $0.01 on S3 and inside the free tier on R2 (inferred). Egress to Amsterdam is about 1 KB per new narinfo (measured sizes 510 to 775 bytes).

Grace window. At least the 3 h builder uptime cap so a session can never lose its own outputs. Suggested 3 days so a closure built for one host survives until that host switches (guess). Lorenzo picks.

## Costs

`bench/cache-cost.py` holds every input. Prices are read. Volumes are guesses anchored on one measured fact: the kernel copy-back was about 52 s at 16 MB/s, about 0.8 GB uncompressed per kernel build (measured earlier, `TRAIL.md`). `ssh_copyback_gb` is the existing remote-build copy-back, identical in every design.

| Scenario | S3 only | R2 only | S3 + R2 mirror |
| --- | --- | --- | --- |
| light, 20 GB cache, 1 kernel bump | $0.50 | $0.15 | $0.64 |
| typical, 50 GB, about 5 GB pushed | $1.32 | $0.60 | $1.89 |
| heavy, 150 GB, 30 GB pushed | $4.40 | $2.10 | $6.38 |
| heavy with the 100 GB AWS free egress used up elsewhere | $9.80 | $7.50 | $11.78 |

R2 saves $0.35 to $2.30 a month in these scenarios (inferred from the model). Egress is $0 until AWS egress for the whole account passes 100 GB a month (read). Today's prototype spend was under $0.001: about 30 PUTs, 100 GETs and 11 MB stored for 3 minutes (inferred from the commands run and the prices above).

## Prototype

Bucket `nbh-cache-proto-845087560967` in eu-north-1, tags `nbh:managed=true` and `nbh:purpose=cache-prototype`, public access blocked (measured). Throwaway key `nbh-cache-proto-1`, public half in `tests/results/cache-proto/key.pub`. Test paths from `cache-gc/proto-paths.nix`.

- Pushed `nbh-proto-root` (references `mid` then `leaf`, plus `hello` and its glibc closure, 8 paths, 11.3 MB zstd) and `nbh-proto-unrelated` with zstd and signing in about 4 s (measured).
- Wrote `roots/proto-host` with only the root toplevel, so the closure is found by walking references.
- Pushed `nbh-proto-recent` unsigned (0 `Sig:` lines), then signed it in place with `nix store sign --store s3://…` (1 `Sig:` line after, measured).
- GC with grace 45 s dry-run, then grace 60 s twice. Run 1 deleted `hysfz5hg…-nbh-proto-unrelated.narinfo` and its nar, kept 9 live (8 rooted plus the recent one). Run 2 deleted nothing (measured, `gc-run1.json`, `gc-run2.json`).
- `nix copy --from` into a fresh local store copied the 8-path rooted closure and the recent path (measured). With no trusted key it failed with "lacks a signature by a trusted key" (measured). The swept path gave "is not valid" and HeadObject returned 404 (measured).
- A plain `nix path-info --store s3://…` still printed the swept path from the local narinfo cache until run with `narinfo-cache-positive-ttl=0` (measured). That is the stale-cache case in the table.
- Bucket emptied (0 versions, 0 delete markers), deleted, HeadBucket 404, no `nbh-cache*` bucket listed (measured).

R2 was not prototyped, no Cloudflare resource was created. Nix 2.35 accepts `s3://<bucket>?endpoint=https://<account>.r2.cloudflarestorage.com&region=auto` and sends a path-style request to `https://<account>.r2.cloudflarestorage.com/<bucket>/nix-cache-info` (measured with a fake account id, which fails at TLS). R2 documents `auto` as the region, with `us-east-1` as an alias (read). The box egresses through Cloudflare in Amsterdam, so a box-to-R2 latency number would not represent Lorenzo's network and was not taken. To run the same prototype on R2: one bucket with location hint `weur`, one account-scoped API token with Object Read and Write on that bucket, the account id, and `--endpoint` on `nbh-cache-gc.py`.

## Open decisions for Lorenzo

1. R2 or S3. R2 is cheaper by $0.35 to $2.30 a month but adds a Cloudflare credential to the gate. S3 keeps everything in account 845087560967.
2. Private bucket with a read credential on each host, or public reads. Public is simpler for hosts but publishes every path he builds.
3. Grace window. 3 h minimum, 3 days suggested.
4. Who signs. Client-side signing after a NarHash check (recommended) or a builder-held key.
5. Whether hosts also push what they build locally, or only builders push.

## Sources

- Nix S3 store settings: https://nix.dev/manual/nix/2.28/store/types/s3-binary-cache-store
- Nix source: `src/libstore/binary-cache-store.cc` and `src/libstore/build/substitution-goal.cc` on NixOS/nix master
- niks3: https://github.com/Mic92/niks3 README, `server/pg/query.sql`, `cmd/niks3/main.go`
- Attic: https://docs.attic.rs/admin-guide/deployment/nixos.html, `server/src/config-template.toml`, README
- Cachix: https://www.cachix.org/pricing
- S3 lifecycle: https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-expire-general-considerations.html
- S3 pricing: https://aws.amazon.com/s3/pricing/ and AWS Price List API (`pricing get-products`, AmazonS3 and AWSDataTransfer, eu-north-1)
- AWS free egress: https://aws.amazon.com/about-aws/global-infrastructure/global-network/faqs/
- R2 pricing: https://developers.cloudflare.com/r2/pricing/
- R2 S3 compatibility and region: https://developers.cloudflare.com/r2/api/s3/api/
- R2 temporary credentials: https://developers.cloudflare.com/r2/api/s3/temporary-credentials/
