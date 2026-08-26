---
name: dsm-validate
description: Bulk-validate DatastoreMigration CRDs (kubedb Redis -> opstree, kubedb Postgres -> CNPG, and kubedb Elasticsearch -> opensearch-operator) before confirming cleanup. Read-only; classifies each migration GREEN/YELLOW/RED and prints the confirm command for the safe ones. Trigger on "validate migrations", "check the dsms", "are these migrations safe to complete", "verify datastore migrations".
---

# dsm-validate

Validate a batch of `DatastoreMigration` CRDs before you annotate them for cleanup. Confirming a migration is **destructive** — it deletes the source PVC — so this checks each one is genuinely healthy first, then hands you the confirm command only for the ones that pass.

**Three migration shapes, auto-detected per DSM** (discriminator: `spec.targetProvider` or the per-type `status.<type>` block):

- **redis** (`kubedb -> opstree`): rsync + AOF/RDB boot-log logic. This is the original path — everything below about rsync, `DBSIZE`, the boot log, and the 0-keys trap applies to it.
- **postgres** (`kubedb -> cnpg`): `pg_dump -> PVC -> pg_restore` into a CNPG `Cluster`. Different ground truth — see the **Postgres (kubedb -> cnpg)** section below.
- **elasticsearch** (`kubedb -> opensearch-operator`): rsync of the node's data directory into a PVC an `OpenSearchCluster` adopts. Ground truth is that cluster plus its index list — see the **Elasticsearch (kubedb -> opensearch-operator)** section below.

Only DSMs at `phase=AwaitingConfirmation` are scored; anything earlier (e.g. `PreflightComplete`) is reported as *in progress* and skipped — it isn't broken, just not ready to confirm.

Read-only by default — it never annotates, restarts, or deletes a migration or its data. The optional `--source-check` mode is the one exception (redis-only): it creates and deletes a short-lived pod that mounts the source PVC `readOnly` (see below).

**Default mode is light-touch:** a couple of `kubectl logs`/`get` reads per DSM (conditions, rsync job, target readiness) and, for redis, the boot log — no `exec`, no on-disk scan. The whole batch runs in seconds. For **postgres and elasticsearch the default does exec once** to probe the restored data (read-only `psql` SELECTs / `_cat/indices` GETs): there is no log-shaped substitute for "did the data land". The precise-but-heavy redis path — `exec redis-cli DBSIZE` plus a static scan of the on-disk `appendonlydir/*.incr.aof` — is behind `--deep`, for the ambiguous cases light-touch escalates to. `--source-check` and `--scan-source` imply `--deep`.

## When to use

After running one or more `DatastoreMigration`s that are sitting at `AwaitingConfirmation`, when you want to clear the safe ones in bulk instead of eyeballing each `kubectl get dsm -o yaml` by hand.

## Run it

```bash
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh              # all namespaces, all types, light-touch
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh idp auditlog # only these namespaces
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --type=postgres        # only postgres DSMs
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --type=redis,postgres  # csv; either type
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --type=elasticsearch   # only ES DSMs (aka es, opensearch)
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --deep greenhouse   # deep probe (exec)
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --deep greenhouse/foo-kubedb-to-ot # one DSM only (ns/name)
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --source-check   # deep + source-PVC scan (redis only)
```

Requires `kubectl` (pointed at the right cluster/context) and `jq`.

### Datastore types

Each DSM is auto-classified by datastore type, and `--type=<csv>` restricts the batch to the type(s) you name (synonyms accepted: `pg`→`postgres`, `ot`/`opstree`→`redis`, `es`/`opensearch`→`elasticsearch`, `memcache`→`memcached`).

**Supported today: `redis`, `postgres`, `elasticsearch`.** Any other detected type (`memcached`, `unknown`, …) is reported `UNSUPPORTED` — flagged for a manual look, never auto-GREEN. Adding a type is the forwards path and is deliberately small: write an `eval_<type>()` in the script, add a `case` arm to the `eval_dsm` dispatcher, and list the type in `SUPPORTED_TYPES`. The classifier prefers explicit signals (`spec.targetProvider`, the per-type `status.<type>` block) and falls back to the datastore name.

## What it checks per DSM (redis)

Postgres and elasticsearch have their own sections below; this one is the redis path.

**Light-touch (default) — all from `kubectl get`/`logs`, no `exec`:**

1. All `status.conditions` are `True` (`PreflightComplete`, `OldInstanceStopped`, `DataSynced`, `NewInstanceReady`, `HandoffComplete`).
2. The rsync `Job` reached `Complete`.
3. The target OT pod (`<datastore>-0`, the opstree redis pod) is `Ready` — a plain `kubectl get pod`. Not Ready → `RED`.
4. The redis **boot log** (`keys loaded: N`, load errors) — the ground truth for whether the migrated data actually loaded (see below). `keys loaded: N>0` with no errors → **GREEN**. Load errors → **YELLOW**. `keys loaded: 0`/missing (empty base RDB) → light-touch can't see the incr AOF, so → **YELLOW** with a `re-run --deep` hint.

The rsync job's `total size is N` is reported as context alongside the boot log.

**`--deep` (escalation) — adds one `exec` per Ready target:**

5. `DBSIZE`, plus a single-pass static scan of the on-disk `appendonlydir/*.incr.aof`, splitting non-health-checker SET keys into **total** (`nonHC_sets`) vs **genuinely durable / no-inline-TTL** (`nonHC_durable`). The durable split is derived from each SET command's arity — `SET k v` is 3-arg, `SET k v PXAT ts` / `SET k v EX n` is 4+ and expires — so a `DBSIZE=0` whose keys were *all* TTL-stamped is scored `GREEN`, no source dig.
6. **rsync-vs-reality:** compares the `total size is N` the rsync job logged against the target redis dir's on-disk size. If rsync claims a substantial transfer (>1 MB) the disk doesn't reflect (< half), the data may not have landed → `YELLOW`. Normally, though, **rsync is trusted** — a `Complete` job with a sane `DBSIZE` needs no source dig.

## The 0-keys trap (the reason this skill exists)

`DBSIZE == 0` on the target is **not** automatically a failed sync.

kubedb writes a `kubedb_health_checker` probe key every ~10s with a short TTL. An idle/dev instance with no real workload accumulates a large AOF (seen: 60 MB / 760k SETs) that is *entirely* churn on that one ephemeral key. Once the source is stopped every key's `PXAT` is in the past, so the AOF replays to **0 live keys — which is correct**. A pod restart that forces a full replay still lands at 0.

### The boot log is ground truth (read this before trusting DBSIZE)

`DBSIZE` is a point-in-time count and **cannot** tell a *failed load* from a *loaded-then-expired* dataset. The redis **boot log** can:

```log
Done loading RDB, keys loaded: 36, keys expired: 0
DB loaded from base file appendonly.aof.2.base.rdb
DB loaded from incr file appendonly.aof.2.incr.aof
Ready to accept connections
```

`keys loaded: N` with a clean `Ready to accept connections` means the migrated data **loaded fine**. If `DBSIZE` is later 0, that's TTL expiry of cache/ephemeral keys (any durable or future-TTL key would still be live) — **benign**. `keys loaded: 0` with data still on disk is a genuine un-replayed/failed load. The skill greps `kubectl logs` for `keys loaded: N` and load-error lines.

**Light-touch (default)** resolves the common cases from the boot log alone:
- boot log shows `keys loaded: N>0`, no errors → data replayed (any later `DBSIZE==0` is benign TTL expiry) → **GREEN**.
- `keys loaded: 0` or no `keys loaded` line (empty base RDB) → real data, if any, is in the incr AOF that light-touch does not scan → **YELLOW** with a `re-run --deep` hint. (A dev/idle env whose base was empty and whose only writes were TTL'd cache keys lands here — `--deep` confirms it's genuinely empty.)
- redis logged load errors → **YELLOW**.

**`--deep`** adds `DBSIZE` + the on-disk durable split to settle the `keys loaded: 0` case without a restart:
- `DBSIZE > 0` → data loaded → **GREEN**.
- `DBSIZE == 0`, empty base **and** `nonHC_durable == 0` → every real key carried an inline TTL (or source was empty) → expired on load → **GREEN**.
- `DBSIZE == 0`, `keys loaded: 0` **and** `nonHC_durable > 0` (a genuine no-TTL key on disk), or redis logged load errors → **YELLOW**.

`nonHC_durable` is a conservative upper bound (a no-TTL key SET then later deleted/overwritten still counts — e.g. the `__redisdump_total_keys` tooling artifact), so it leans toward `YELLOW`/escalation rather than a false `GREEN`. The boot log stays the strongest signal; the durable split is what lets a `DBSIZE=0` resolve under `--deep` without falling back to `--source-check` or a restart.

## RED from a not-Ready pod + a multi-GB transfer — two causes, disambiguate FIRST (redis)

A `notReady`/crashlooping target with a multi-GB rsync has **two distinct causes with opposite fixes**. Do not assume the AOF-replay crashloop — **read `lastState.terminated` before deciding**:

```bash
kubectl get pod <datastore>-0 -n <ns> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
```

- reason=`OOMKilled` exit=`137` → **Cause A: OOM** (dataset too big for the memory limit).
- reason=`Completed` exit=`0` → **Cause B: AOF-replay-vs-liveness crashloop**.

Also grep the boot log for `RDB memory usage when created N Mb` — that is the in-memory keyspace size. Compare it to the container memory *limit* (`kubectl get pod ... -o jsonpath='{.spec.containers[0].resources.limits.memory}'`). N ≳ limit points at Cause A regardless of AOF size.

### Cause A — OOMKilled (genuinely large keyspace)
`OOMKilled`/`137`, and `RDB memory usage when created` exceeds the limit. This is real data that doesn't fit in RAM (seen: 1.44 GB / 71,839 keys into a 512Mi limit). `BGREWRITEAOF` / wider probes do **not** help — they shrink disk/replay-time, not the in-memory footprint; peak RSS on load ≈ final dataset size.
- **Fix:** raise the memory limit at the **`Datastore` CR** (`spec.k8sRedis.resources.limits.memory`) — top of the `Datastore → Redis CR → STS` chain. Editing the Redis CR or STS gets reverted (datastore-controller / opstree operator reconcile them back).
  ```bash
  kubectl patch datastore.datastore.greenhouse.io <name> -n <ns> --type merge \
    -p '{"spec":{"k8sRedis":{"resources":{"limits":{"memory":"2Gi"}}}}}'
  ```
- **Then unstick the rollout:** after the limit cascades to the STS, the crashlooping pod won't roll on its own — StatefulSet RollingUpdate waits for the current pod to be Ready before replacing it, so a never-Ready pod deadlocks its own upgrade. `kubectl delete pod <datastore>-0 -n <ns>` once the STS template shows the new limit; it recreates on the update revision. Confirm success: `keys loaded: N` in the boot log + `Ready to accept connections`.

### Cause B — AOF-replay-vs-liveness crashloop (churn AOF, tiny keyspace)
A huge uncompacted source AOF (e.g. 8 GB for ~5 real keys) takes longer to replay than the liveness probe's grace, so redis is killed mid-replay before it can answer `PING` — a restart loop.
- **Confirm:** logs end with `Received shutdown signal during loading`; graceful SIGTERM (`Completed`/`0`, **not** `OOMKilled`/`137`); memory tiny vs limit; CPU pegged replaying.
- **Fix:** widen `initialDelaySeconds` + `failureThreshold` on the **opstree `Redis` CR** (`redis.redis.redis.opstreelabs.in` — fully-qualified; the short name collides with kubedb `redises`), *not* the STS/pod (the operator reverts direct edits). Enough grace to survive one full replay; redis then auto-rewrites the AOF to ~KB and every later boot is instant (self-heals).
- **Prevent:** pre-compact the source (`BGREWRITEAOF` or ship the RDB) before migrating, and set a sane default probe grace in the operator's target template.

## Source-side check (option 2) — ask before escalating

A lightweight second opinion against the *source* PVC, worth it only when the target already looks off. A default run **never** touches the source; it just flags suspicious DSMs (`DBSIZE == 0` or rsync/disk mismatch) and prints `source-check available: re-run with --scan-source=<ns/name>`.

**Do not auto-escalate.** For each suspicious DSM, ask the operator whether to source-check it or just trust rsync — some they'll want to wave through. Drive it like this:

1. Run the validator read-only (no flags). Note the suspicious/YELLOW DSMs.
2. For each suspicious DSM, ask (one batched round): **source-check it** / **trust rsync & confirm anyway** / **hold**.
3. Re-run `--scan-source=ns/name[,ns2/name2]` for only the ones they chose to check. The others get their confirm command (trust) or are left alone (hold).

Modes (both imply `--deep` — the target probe has to run to decide what's suspicious):
- `--scan-source=ns/name,...` — source-check **only** these specific DSMs (the targeted, operator-approved path).
- `--source-check` — source-check **every** suspicious DSM in one shot (unattended; use when you don't want to be asked).

For a scanned DSM it spins a short-lived pod that mounts the source PVC `readOnly`, then (no redis boot — the source data is never modified):
- statically scans the source `appendonlydir/*.incr.aof` for durable (non-health-checker, no-inline-TTL) SET keys, and
- counts keys in the source AOF `base.rdb` via `redis-check-rdb`.

It compares that upper-bound against the target `DBSIZE`:
- source shows durable keys but target is empty → **YELLOW** (data didn't make it — do not confirm).
- source also shows 0 durable keys → confirms the empty target is correct, verdict stays as-is.

This only works while the migration is at `AwaitingConfirmation` (the source PVC still exists). After `Completed` the source is deleted (`enc-gp3` is `reclaimPolicy=Delete`).

> **Untested against a live source.** The `--source-check` path was written but never exercised end-to-end — there were no `AwaitingConfirmation` DSMs left when it was added. Sanity-check its output the first time you use it.

## Postgres (kubedb -> cnpg)

Everything above (rsync, `DBSIZE`, boot log, the 0-keys trap, `--source-check`) is **redis-only**. Postgres migrations are a different shape and are validated differently — but the CLI, flags, and GREEN/YELLOW/RED verdicts are the same.

**The migration:** `pg_dump` on the source kubedb PVC → a dump PVC → `pg_restore` into a **CNPG `Cluster`** named after the datastore (`status.postgres.{dumpJobName,restoreJobName,dumpPVCName,sourcePVCName}` record the pieces). The dump/restore `Job`s are usually GC'd by the time a DSM reaches `AwaitingConfirmation`, so they are **not** a reliable signal — the ground truth is the CNPG cluster itself.

**What it checks per DSM (light-touch default):**

1. All `status.conditions` are `True` (same five: `PreflightComplete`, `OldInstanceStopped`, `DataSynced`, `NewInstanceReady`, `HandoffComplete`).
2. The CNPG `Cluster` (name == datastore name) is **healthy**: `status.phase` is `Cluster in healthy state` and `status.readyInstances == spec.instances`. Primary pod is read from `status.currentPrimary` (CNPG numbers it `-1`, **not** the redis `-0`). Not healthy / missing → `RED`.
3. **Data probe** (read-only `psql`, SELECT only, on the primary): lists non-system databases with `pg_database_size`, then for the largest (the app db) reports the **user-table count**, total size, and the **top 10 tables** by size with a `reltuples` row estimate. An app db with **0 user tables** → `YELLOW` (restore may not have landed). No non-system db at all → `YELLOW`.

**`--deep`:** swaps the `reltuples` estimate for an exact `COUNT(*)` on each of the top-10 tables (heavier — one `psql` per table). Everything else is identical.

`--source-check` / `--scan-source` are **not implemented** for postgres (they'd need to spin postgres on the source PVC); a postgres DSM targeted with them prints a note and validates the target cluster only.

**Verdicts for postgres:**
- **GREEN** — conditions all `True`, cluster healthy, app db present with ≥1 user table.
- **YELLOW** — cluster healthy but the app db has 0 user tables, or no application db exists (restore may not have loaded). Investigate before confirming — cleanup deletes the source PVC.
- **RED** — a condition is not `True`, or the CNPG cluster is missing / not healthy.

## Elasticsearch (kubedb -> opensearch-operator)

Everything in the redis sections (rsync, `DBSIZE`, boot log, the 0-keys trap, `--source-check`) is **redis-only**. Elasticsearch is a third shape, with the same CLI, flags, and GREEN/YELLOW/RED verdicts.

**The migration** is a hard-downtime PVC handoff. Preflight copies the source admin password into the target's `<name>-admin-credentials` Secret, pre-creates the target PVC (`data-<name>-nodes-0`), and pins the source PV to `Retain`. StopOldInstance halts the KubeDB CR. SyncData rsyncs the data directory. Handoff deletes the two colliding cert Secrets and flips the backend annotation. **PostCutover** then drops the `kubedb-system` index and sets `auto_expand_replicas: 0-1` on `.opendistro-ism-config` — it deliberately runs *before* `AwaitingConfirmation`, so what you inspect in this window is the finished state. Cleanup (on confirm) deletes the KubeDB CR, the source PVC, the orphaned credential Secrets, and restores the PV reclaim policy.

Only the data directory moves, so the target inherits the source's security index — that is why the password is carried over rather than regenerated, and why the probe reads `<name>-admin-credentials`.

**Ground truth is the `OpenSearchCluster` plus its index list**, not the rsync job.

**What it checks per DSM (light-touch default):**

1. All `status.conditions` are `True` (the same five).
2. The rsync `Job` reached `Complete`; its `total size is N` is reported as context. **A missing Job is not a failure** — a finished Job is TTL-GC'd long before an operator gets round to confirming, so an absent one is reported `rsync=gc` and the copy is attested by `DataSynced`/`HandoffComplete` instead (the same reason postgres does not key on its dump/restore Jobs). Only a Job that exists and is *not* `Complete` scores `RED`.
3. The `OpenSearchCluster` is `status.phase == RUNNING` with `availableNodes >= 1`. Missing or not RUNNING → `RED`.
4. The target pod `<name>-nodes-0` is `Ready` → else `RED` (and the index probe is skipped, so the verdict is never a false GREEN).
5. **Index probe** (read-only `_cat/indices` from inside the node pod, over https with the admin credentials): counts **user** indices — excluding dot-prefixed system indices and `kubedb-system` — and their doc totals. 0 user indices → `YELLOW`.
6. `kubedb-system` still present → `YELLOW`. PostCutover runs before this window, so its survival means that Job did not finish.
7. Health `yellow`/`red` → one `_cat/shards` read to tell a structural yellow from a real one (below).

**`--deep`:** a per-index `_count`. `_cat/indices` reads cluster-state metadata; `_count` actually reads the shards, so it catches an index that is listed but unsearchable.

### The yellow-health trap (elasticsearch's analogue of the 0-keys trap)

`cluster health == yellow` is **not** automatically a failed migration.

These datastores run single-node. Any index carrying `rep >= 1` can never assign its replica on one node, so the cluster sits yellow permanently — structural, not data loss. `.opendistro-ism-config` is the one that bites: the ISM plugin creates it with a **fixed one replica**, which is exactly what PostCutover's `auto_expand_replicas: 0-1` exists to fix.

So the shard probe decides, not the health colour:

- unassigned **primary** → `RED`. Genuinely missing data.
- unassigned **replicas only** on a single node → `GREEN`, with a note saying why. Expected.
- `.opendistro-ism-config` unassigned → `YELLOW`. PostCutover is what fixes this, so it likely did not run — check the `<dsm>-post-cutover` Job.
- unassigned replicas on a **multi-node** cluster → `YELLOW`. Those should have assigned.

### Gotcha: `OpenSearchCluster` is an ambiguous kind

Two CRDs claim the kind *and* the `os`/`opensearch` shortnames:

```
opensearchclusters.opensearch.org        <- datastore-controller writes this one
opensearchclusters.opensearch.opster.io
```

A bare `kubectl get opensearchclusters` is **ambiguous, not merely verbose** — it can resolve to the wrong group and report "not found" for a cluster that exists. Always fully qualify `opensearchclusters.opensearch.org`.

### What this cannot check: a pre-migration baseline

The skill sees only the post-migration cluster, so it can tell you the indices are *present and searchable* but not that they are *complete*. For a migration you care about, capture a baseline before you start and diff it after:

```bash
# before (source pod, kubedb naming)
PW=$(kubectl get secret -n <ns> <name>-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n <ns> <name>-0 -- \
  curl -sk -u "admin:$PW" 'https://localhost:9200/_cat/indices?v&s=index' > /tmp/es-before.txt

# after (target pod, operator naming + the new credentials secret)
PW=$(kubectl get secret -n <ns> <name>-admin-credentials -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n <ns> <name>-nodes-0 -- \
  curl -sk -u "admin:$PW" 'https://localhost:9200/_cat/indices?v&s=index' > /tmp/es-after.txt

diff /tmp/es-before.txt /tmp/es-after.txt
```

`kubedb-system` disappearing is expected — PostCutover drops it.

**Verdicts for elasticsearch:**
- **GREEN** — conditions all `True`, cluster `RUNNING`, pod `Ready`, at least one user index present. A single-node replica yellow is noted, not penalized.
- **YELLOW** — 0 user indices, `kubedb-system` survived, a yellow health it cannot attribute to the single-node replica effect, or the probe could not run (missing credentials, unreadable endpoint). An unverified target is never GREEN.
- **RED** — a condition not `True`, an rsync Job that exists but is not `Complete` (a GC'd Job is not a failure — see above), the `OpenSearchCluster` missing or not `RUNNING`, the pod not `Ready`, or an unassigned primary shard.

`--source-check` / `--scan-source` are **not implemented** for elasticsearch (they would need to boot opensearch against the source PVC); a targeted DSM prints a note and validates the target only.

**Rollback stays open until you confirm.** Handoff halts the KubeDB CR rather than deleting it, and only removes the regenerable `-admin-cert` / `-transport-cert` Secrets. Cleanup is what deletes the source — the controller's own `AwaitingConfirmation` message says so ("deleting it ends the unhalt rollback path"). So a YELLOW here is recoverable; a YELLOW you confirmed anyway is not.

## Verdicts

- **GREEN** — safe to confirm. The script prints the exact annotate command; run it yourself.
- **YELLOW** — needs a human. Investigate (restart + re-check, or diff against the source PVC) before confirming.
- **RED** — broken (a condition not True; for redis: rsync incomplete or pod not Ready; for postgres: CNPG cluster missing/unhealthy; for elasticsearch: OpenSearchCluster missing/not RUNNING, pod not Ready, or an unassigned primary shard). Do not confirm.

## Confirming (you run this, not the skill)

```bash
kubectl annotate DatastoreMigration -n <ns> <name> datastore.greenhouse.io/migration-confirm-cleanup=true
```

## Deeper manual check for a YELLOW / suspicious 0 (redis)

Redis-only — the commands below assume an AOF/RDB on-disk layout. For an elasticsearch YELLOW see
the baseline-diff and PostCutover checks in its own section; for postgres, probe the CNPG primary.

Back up first (the source PVC gets deleted on confirm):

```bash
kubectl exec -n <ns> <datastore>-0 -c <datastore> -- tar czf - -C /data appendonlydir dump.rdb > backup.tgz
```

Then restart to force a replay and re-check:

```bash
kubectl delete pod <datastore>-0 -n <ns>      # StatefulSet recreates it; redis replays the AOF on boot
# then re-run dsm-validate.sh --deep <ns>
```
