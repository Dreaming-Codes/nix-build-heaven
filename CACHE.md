# Shared binary cache, phase 1

Status: deployed on 2026-10-21 as `nbh-cache-845087560967` (see Deployment). The hosts switch to it with the nixos branch `nbh-cache-client`, which is not pushed. Builders push once the AMI is re-baked.

Goal, in Lorenzo's words: "a shared nix build cache that can be used both my machines and the builders. We need the cache to not blow in size so we should only keep what is used in the flake currently, if there's no proper way to do this we can probably do a time retention period".

Who notices. DreamingDesk and DreamingBlade stop rebuilding what the other host or a builder already built, and a builder stops rebuilding its own last outputs. The next maintainer inherits one bucket, one signing key, a root-file convention and one GC command.

Labels. (measured) means seen this session. (read) means taken from a doc or source file listed under Sources. (inferred) follows from those. (guess) is a prediction.

## Comparison

Prices: S3 Standard eu-north-1 $0.023/GB-month, PUT and LIST $0.005 per 1k, GET $0.0004 per 1k, internet egress $0.09/GB after 100 GB/month free across the whole AWS account (read, AWS Price List API and the S3 pricing page). S3 to EC2 in the same region is free (read, S3 pricing page). R2 Standard $0.015/GB-month, Class A $4.50/M, Class B $0.36/M, egress free, free tier 10 GB-month, 1M A, 10M B, deletes free (read, R2 pricing page). EC2 to the internet, which includes EC2 to R2, is the same $0.09/GB AWS egress line (read, Price List API `EUN1-DataTransfer-Out-Bytes`).

| Design | Who writes | Who reads | GC | Always on | ~50 GB/month | His machines' egress |
| --- | --- | --- | --- | --- | --- | --- |
| Plain S3 bucket, `s3://` store | Builders in-region for free (instance profile or gate-minted session creds), or hosts with `nix copy` | Builders free in-region, hosts over the internet | None built in. Bring your own (this doc) | Nothing | $1.15 storage + cents of requests (inferred) | $0.09/GB after the shared 100 GB free (read) |
| Plain R2 bucket, `s3://…?endpoint=…&region=auto` | Builders pay AWS egress $0.09/GB to push (read). Hosts push free | Everyone, egress free (read) | Same bring-your-own GC. R2 lifecycle exists but is age-based | Nothing | $0.60 (50 GB minus 10 free, inferred). His measured 6 GB is free | $0 (read) |
| niks3 (Mic92) on S3 or R2 | `niks3 push` asks the server for presigned URLs, then PUTs to the bucket (read) | Straight from the bucket (read) | Closures older than `--older-than` (default 720h) and not pinned are dropped, reachability walked in Postgres, orphans marked then deleted after a grace period (read, `server/pg/query.sql`, `cmd/niks3/main.go`) | niks3 server plus PostgreSQL (read) | Bucket cost plus a host for the server (guess: $4+/month for the smallest VM) | Same as the bucket under it |
| Attic | `attic push` to atticd, which chunks and dedups (read) | Through atticd, which signs on the fly (read) | Time-based retention per cache, run every 12 h by default, LRU by access (read, `config-template.toml`, README) | atticd plus a DB (read) | Bucket cost plus a host (guess, as niks3) | Through the server, so the server's egress |
| Cachix | `cachix push` | cachix.org CDN | LRU eviction once the storage limit is hit (read, pricing FAQ) | Hosted | Starter plan is 50 GiB, price is "contact" on the page today (read) | Unlimited bandwidth (read) |
| S3 or R2 lifecycle expiry only | Anyone | Anyone | Deletes by object age, not last use (read, S3 lifecycle doc) | Nothing | Bucket cost | Bucket rate |

Why lifecycle alone is wrong here. Expiry counts from object creation (read). Nix never re-uploads a path whose `.narinfo` exists (read, `binary-cache-store.cc` `isValidPathUncached` and `uploadData` skip), so glibc for the running system expires on day N while it is still in use (inferred). Expiry also deletes `.narinfo` and `nar/` independently, so a live narinfo can point at a deleted nar, or a path can lose a reference (inferred). A bucket policy cannot stop a lifecycle delete (read).

## Recommendation

A plain bucket plus our own root-based mark and sweep, run by the gate. No server.

Bucket. S3 in eu-north-1, account 845087560967. Lorenzo's rule is "everything on AWS unless R2 is importantly cheaper". Measured on his flake, R2 saves $0.24 a month with the recommended push policy and $0.61 a month if the full closure were pushed (see Costs). That is negligible, so S3 (inferred from the model). Builders read and write S3 in-region for free (read), and IAM stays in one account. R2 becomes worth a second look only if the whole AWS account goes past 100 GB of internet egress a month, and even then the gap is under $2 a month at these volumes (inferred).

Push policy. Push only paths that no public cache has (policy A). Hosts keep pulling everything else from cache.nixos.org and install.determinate.systems for free. Pushing the full closure (policy B) multiplies the cache by 7 and the weekly push by 7 for no gain while upstream keeps old paths (inferred from the measured sizes).

Why not niks3 or Attic. Both do the right GC, niks3 almost exactly the root model below with "pins", but both need an always-on server and a database, which this project rules out (read for the requirement, inferred for the fit). niks3 stays the fallback if the root files below turn out too fragile.

Signing. The key stays on Lorenzo's machine. Builders upload unsigned. After copy-back the client signs only the narinfos whose NarHash matches its own copy, with `nix store sign --store <cache>` (measured to work against S3, see Prototype). A builder never holds a long-lived key, which matters because fixed-output derivations get network access and can reach IMDS user-data (inferred).

Writes. Builders push in their session with `post-build-hook` or a `nix copy` at session end, using credentials minted by the gate per launch. On S3 that is a session policy or instance profile with PutObject and GetObject but no DeleteObject. On R2 it is a temporary credential signed locally by the gate with `actions` that omit DeleteObject and a short `ttlSeconds` (read, R2 temporary credentials doc). Only the gate's GC deletes.

## Roots and GC

Roots. One small object per thing to keep, `roots/<name>`, holding store paths one per line. GC treats every listed path as live and walks `References:` from it, so a root may list just a toplevel or a full `nix path-info -r` closure. The full closure is safer: it keeps a host's paths even if its toplevel itself was never pushed (inferred).

- `roots/DreamingDesk` and `roots/DreamingBlade` are rewritten on every switch from an activation hook or a small unit, from `/run/current-system`. Adding `/run/booted-system` to the same file keeps the reboot target. Old generations are not roots, which is the "only what the flake uses currently" rule.
- `roots/builder-ami` is written by `upload-ami.sh` only if builders ever substitute their own image paths. The AMI itself is an EBS snapshot and does not need the cache.
- Session roots are not built. The 14-day grace window and push's narinfo refresh keep a session's outputs until the hosts switch and root them (inferred).

Algorithm (`cache/nbh-cache.py gc`).

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

Where GC runs. In `scripts/cache-publish.sh` after a session's push and sign, at most once per 24 h through a stamp file, plus a manual `nbh-cache gc`. No Lambda and no builder involvement. Each run lists the bucket and GETs live narinfos. At the guessed 20k objects that is well under $0.01 (inferred).

Grace window. 14 days, Lorenzo's call, for extra safety since S3 is cheap. It must stay above the 3 h builder uptime cap so a session never loses its own outputs. Over the 3-day suggestion it keeps about 11 more days of weekly pushes, about 4 GB or $0.10 a month more (inferred from the 1.96 GB weekly delta at $0.023/GB-month). `push` re-PUTs the narinfo of every path it finds already present, so the window counts from the last push that needed a path, not its first upload.

## Measured closure

Workflow it models. A weekly bot runs `nix flake update`, builds DreamingDesk and DreamingBlade on the builders and pushes the lock. The hosts pull and switch, ideally building nothing.

Method. `nix-instantiate` of each toplevel (no build), `nix derivation show -r`, then a walk from the toplevel that stops at any derivation whose needed outputs have a narinfo on install.determinate.systems, cache.nixos.org, nix-community.cachix.org, numtide.cachix.org or cache.nixos-cuda.org (the flake's own substituters). Everything the walk does not stop at must be built and is what our cache stores. Scripts are `bench/closure-split.py`, `bench/fod-sizes.py` and `bench/cache-sizes.py`. Output in `tests/results/cache-proto/sizes.json`.

Locks. Current is `nbh-drop-xinux-kernel` (nixpkgs 6aa7ad7, 2026-10-12). The weekly pair is lock `aa2135b` (nixpkgs 91a5f61, 2026-10-09) against lock `cfc5996` from `auto-update-flake` (nixpkgs 8d71b6f, 2026-10-15), 6.7 days apart, both on the same config. `master` gives the same derivation counts as the branch (measured). It differs only in substituting the kernel from cache.xinux.uz.

| Now (2026-10-12 lock) | DreamingDesk | DreamingBlade | Both, deduped |
| --- | --- | --- | --- |
| Derivations in the graph | 18,836 | 20,739 | |
| Paths to build, our cache | 472 | 607 | 726 |
| Of those, fixed-output downloads | 39 | 43 | |
| Our cache, NAR | 7.4 GB | 7.2 GB | 7.7 GB |
| Our cache, compressed | 3.4 GB | 3.9 GB | 4.1 GB |
| Public-cache paths reachable (upper bound of the runtime closure) | 3,330 | 3,683 | 3,734 |
| Their NAR / compressed | 41.4 / 14.7 GB | 48.7 / 21.7 GB | 52.7 / 24.0 GB |

| Per week | Value |
| --- | --- |
| New paths to build | 272 |
| New in our cache, NAR / compressed | 3.45 / 1.96 GB |
| Of the compressed, measured | 0.84 GB |
| New public-cache paths (upper bound) | 373, 12.4 GB compressed |
| Each host pulls from our cache | DreamingDesk 1.11 GB, DreamingBlade 1.07 GB |

What is measured and what is not. Counts and every public-cache size are measured from narinfo `NarSize` and `FileSize`. Fixed-output downloads (Cursor 307 MB, Zoom 303 MB, CachyOS source 266 MB, Helium 159 MB, two nix-index databases 107 MB each, Slack 94 MB, Discord parts) are measured by HTTP Content-Length. The kernel outputs we built are measured from the box store: `kxs8…` 25.8 MB, `vn1lzz4b…-modules` 162 MB, `z2wks294…-dev` 639 MB NAR. Every other built path is a guess. A package that unpacks a download is twice the download, anything else is 0.5 MB, and compression follows the measured public-cache ratio of 0.36 to 0.45. Most of the built set is unfree software cache.nixos.org never builds (Cursor, Zoom, Discord, Slack, Helium, Steam, saleae-logic, hplip), the kernel, and NixOS config and unit files.

The kernel did not change in this week (measured). Its five output paths per host are identical in all three locks because `nix-cachyos-kernel` stayed at b1332396. A kernel bump costs about 0.85 GB NAR in our cache (0.83 GB of it measured) and about 0.19 GB per host to pull (measured kernel and modules NAR).

The "public-cache paths reachable" rows are an upper bound. They are the reference closure of every public path that any built derivation consumes, so they include compilers. The true runtime closure is smaller (inferred). Only policy B depends on this number.

## Costs

`bench/cache-cost.py` holds every price and input. Prices are read. Volumes come from the tables above, a month is 52/12 weeks, and GET counts are a guess (about 4k narinfo lookups per host switch and 20k per builder session, 210k a month). `ssh_copyback_gb` is the existing remote-build copy-back to wherever the weekly bot runs, 3.45 GB NAR a week (inferred from the built NAR delta), and is the same in every design.

| Monthly | S3 only | R2 only | S3 + R2 mirror |
| --- | --- | --- | --- |
| A, push built only, 6.1 GB cache, 8.5 GB pushed, 9.4 GB pulled | $0.24 | $0.00 | $0.19 |
| A plus 4 kernel bumps | $0.25 | $0.00 | $0.21 |
| B, push full closure, 42.5 GB cache, 62 GB pushed, 75 GB pulled | $1.11 | $0.50 | $1.55 |
| B with the 100 GB AWS free egress already used elsewhere | $9.18 | $7.45 | $8.51 |

Verdict. Negligible. With policy A, S3 costs $0.24 a month more than R2, all of it S3 storage and requests. R2 is $0.00 because 6 GB fits its 10 GB free tier (inferred from the model). AWS egress is $0 in both because the account stays under 100 GB a month: S3 hosts pull 9.4 GB, R2 builders push 8.5 GB, plus the 15 GB copy-back (inferred). Policy B widens the gap to $0.61, or $1.73 past the free egress, still small. Policy B is the only case that gets near the 100 GB line, at 90 GB of S3 egress a month.

Biggest egress lever. The 15 GB a month of ssh copy-back to the bot is larger than the cache traffic in policy A (inferred). If the bot builds with `--store ssh-ng://…` or pushes to the cache from the builder and never copies back, that flow goes away. Worth doing in phase 2, whichever bucket.

Prototype spend today was under $0.001: about 30 PUTs, 100 GETs and 11 MB stored for 3 minutes (inferred from the commands run and the prices above).

## Prototype

Bucket `nbh-cache-proto-845087560967` in eu-north-1, tags `nbh:managed=true` and `nbh:purpose=cache-prototype`, public access blocked (measured). Throwaway key `nbh-cache-proto-1`, public half in `tests/results/cache-proto/key.pub`. Test paths from `cache/proto-paths.nix`.

- Pushed `nbh-proto-root` (references `mid` then `leaf`, plus `hello` and its glibc closure, 8 paths, 11.3 MB zstd) and `nbh-proto-unrelated` with zstd and signing in about 4 s (measured).
- Wrote `roots/proto-host` with only the root toplevel, so the closure is found by walking references.
- Pushed `nbh-proto-recent` unsigned (0 `Sig:` lines), then signed it in place with `nix store sign --store s3://…` (1 `Sig:` line after, measured).
- GC with grace 45 s dry-run, then grace 60 s twice. Run 1 deleted `hysfz5hg…-nbh-proto-unrelated.narinfo` and its nar, kept 9 live (8 rooted plus the recent one). Run 2 deleted nothing (measured, `gc-run1.json`, `gc-run2.json`).
- `nix copy --from` into a fresh local store copied the 8-path rooted closure and the recent path (measured). With no trusted key it failed with "lacks a signature by a trusted key" (measured). The swept path gave "is not valid" and HeadObject returned 404 (measured).
- A plain `nix path-info --store s3://…` still printed the swept path from the local narinfo cache until run with `narinfo-cache-positive-ttl=0` (measured). That is the stale-cache case in the table.
- Bucket emptied (0 versions, 0 delete markers), deleted, HeadBucket 404, no `nbh-cache*` bucket listed (measured).

R2 was not prototyped, no Cloudflare resource was created. Nix 2.35 accepts `s3://<bucket>?endpoint=https://<account>.r2.cloudflarestorage.com&region=auto` and sends a path-style request to `https://<account>.r2.cloudflarestorage.com/<bucket>/nix-cache-info` (measured with a fake account id, which fails at TLS). R2 documents `auto` as the region, with `us-east-1` as an alias (read). The box egresses through Cloudflare in Amsterdam, so a box-to-R2 latency number would not represent Lorenzo's network and was not taken. To run the same prototype on R2: one bucket with location hint `weur`, one account-scoped API token with Object Read and Write on that bucket, the account id, and an `--endpoint` flag added back to `cache/nbh-cache.py`, which the deployed tool dropped.

## Decisions

Settled by Lorenzo on 2026-10-21.

1. S3, in eu-north-1 on account 845087560967.
2. Push policy A. Only paths neither install.determinate.systems nor cache.nixos.org serves.
3. Private bucket, one read key per host.
4. Grace window 14 days.
5. Signing by the weekly bot's machine after a NarHash check. Builders hold no signing key.
6. Builders push. Hosts never push their own builds, and IAM enforces it.

## Deployment

Resources (measured, `tests/results/cache-deploy/apply.txt`, `bucket-settings.txt`):
- Bucket `arn:aws:s3:::nbh-cache-845087560967`. SSE-S3 (AES256), all four public access blocks on, BucketOwnerEnforced, TLS-only bucket policy, versioning never enabled, no lifecycle rule. `nix-cache-info` with priority 50 is a tofu object.
- IAM users `nbh-cache-DreamingDesk` and `nbh-cache-DreamingBlade`. Each can list, get, and put only `roots/<itself>`.
- IAM role `nbh-builder` with instance profile `nbh-builder`, on launch template version 4 (measured, `tests/results/builder-role/lt-and-role.txt`). It trusts ec2.amazonaws.com with `aws:SourceAccount` 845087560967. Its only policy lists the bucket and gets and puts `*.narinfo` and `nar/*`. Get is there because push skips existing nars and refreshes existing narinfos. An explicit deny stops it writing `roots/*` and `nix-cache-info`. It has no delete. IMDSv2 is required with hop limit 1.
- `nbh-gate` may pass only that role, and only to ec2.amazonaws.com, through the managed policy `nbh-gate-pass-builder-role`. Its inline policy is at the 2048-byte limit, so the grant could not go there (measured).
- IAM user `nbh-cache-signer`, which replaced `nbh-cache-writer`. Signing on the box is the only push-side job left off the builder, and it only rewrites narinfos. So the signer can list, get `*.narinfo` and `nar/*`, and put `*.narinfo`. It cannot put nars, write roots or `nix-cache-info`, or delete.
- IAM user `nbh-cache-gc`. It can list, get, and delete `*.narinfo`, `*.ls` and `nar/*`. It cannot delete roots or `nix-cache-info` and cannot write.
- Signing key `nbh-cache-845087560967-1`. Its public half is in `nix/cache.nix`.

`infra/cache.nix` holds all of it, applied with `-target` so nothing else changed. The full plan had shown the same 22 additions and no other change (measured).

Why a custom uploader. `nix copy --no-recursive` to the bucket refuses a path whose references are only upstream, with "cannot add ... because the reference ... is not valid" (measured, `tests/results/cache-deploy/nix-copy-policy-a.txt`). So `nbh-cache push` writes the nar and narinfo itself with `nix-store --dump` and zstd. It goes in reference order, nar before narinfo.

Flow after a build session, `scripts/cache-publish.sh`:
1. Over ssh, the builder runs `nbh-cache push` with no credentials file. boto3's default chain takes the `nbh-builder` role from IMDS. No key exists on the builder. It skips paths upstream serves and re-PUTs narinfos already present.
2. The signer runs `nbh-cache sign` with the `nbh-cache-signer` key. It signs only narinfos whose store path is in the expect list from the bot's own evaluation and whose nar decompresses to NarHash and NarSize.
3. `nbh-cache gc` runs with a stamp file, at most once per 24 h.

Hosts use `services.nbh.cache` in `modules/client.nix`. The host sets `account`, `region`, `bucket`, `publicKey` and `credentialsFile`, which have no defaults, so a missing one fails eval. `profile` defaults to `nbh-cache-<host>`. The module adds the `s3://` substituter at priority 50 and the public key, and points nix-daemon's `AWS_SHARED_CREDENTIALS_FILE` at the host key. It also adds a `nbh-cache-roots` unit, triggered by a path unit on `/nix/var/nix/profiles`, which writes the closure of the system profile, `/run/current-system` and `/run/booted-system` to `roots/<host>`.

Builders. `modules/builder.nix` now lists only determinate and cache.nixos.org, with the flakehub -3 and -4 keys and the cache key. An assertion rejects any other substituter. Breaking it once with nixos-cuda failed eval (measured). The re-baked AMI ami-028a6bddd61022087 (launch template version 5) carries it (measured, `tests/results/rebake-3/live/builder.txt`).

IMDS from builds. A fixed-output or `__noChroot` build shares the builder's network. On ami-0dbc5c7676643380c such a build got an IMDSv2 token (measured, `tests/results/builder-role/live/imds-from-build.txt`), so it could take the role. `modules/builder.nix` rejects IMDS traffic from the nixbld group. On ami-028a6bddd61022087 both build kinds get no connection to 169.254.169.254, but they still reach 1.1.1.1. The nbh user, which runs the push, still gets a token and the assumed role (measured, `tests/results/rebake-3/`). No credential is stored on or sent to the builder any more.

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
