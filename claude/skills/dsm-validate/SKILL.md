---
name: dsm-validate
description: Bulk-validate DatastoreMigration (kubedb Redis -> ot) CRDs before confirming cleanup. Read-only; classifies each migration GREEN/YELLOW/RED and prints the confirm command for the safe ones. Trigger on "validate migrations", "check the dsms", "are these migrations safe to complete", "verify datastore migrations".
---

# dsm-validate

Validate a batch of `DatastoreMigration` CRDs before you annotate them for cleanup. Confirming a migration is **destructive** — it deletes the source PVC — so this checks each one is genuinely healthy first, then hands you the confirm command only for the ones that pass.

Read-only by default — it never annotates, restarts, or deletes a migration or its data. The optional `--source-check` mode is the one exception: it creates and deletes a short-lived pod that mounts the source PVC `readOnly` (see below).

**Default mode is light-touch:** two `kubectl logs`/`get` reads per DSM (conditions, rsync job, target-pod readiness, and the redis boot log) — no `exec`, no on-disk scan. The whole batch runs in seconds. The precise-but-heavy path — `exec redis-cli DBSIZE` plus a static scan of the on-disk `appendonlydir/*.incr.aof` — is behind `--deep`, for the ambiguous cases light-touch escalates to. `--source-check` and `--scan-source` imply `--deep`.

## When to use

After running one or more `DatastoreMigration`s that are sitting at `AwaitingConfirmation`, when you want to clear the safe ones in bulk instead of eyeballing each `kubectl get dsm -o yaml` by hand.

## Run it

```bash
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh              # all namespaces, light-touch
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh idp auditlog # only these
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --deep greenhouse   # exec + on-disk AOF scan
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --deep greenhouse/foo-kubedb-to-ot # one DSM only (ns/name)
~/.claude/skills/dsm-validate/scripts/dsm-validate.sh --source-check   # deep + source-PVC scan
```

Requires `kubectl` (pointed at the right cluster/context) and `jq`.

## What it checks per DSM

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

## RED from a not-Ready pod + a multi-GB transfer — two causes, disambiguate FIRST

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

## Verdicts

- **GREEN** — safe to confirm. The script prints the exact annotate command; run it yourself.
- **YELLOW** — needs a human. Investigate (restart + re-check, or diff against the source PVC) before confirming.
- **RED** — broken (a condition not True, rsync incomplete, or pod not Ready). Do not confirm.

## Confirming (you run this, not the skill)

```bash
kubectl annotate DatastoreMigration -n <ns> <name> datastore.greenhouse.io/migration-confirm-cleanup=true
```

## Deeper manual check for a YELLOW / suspicious 0

Back up first (the source PVC gets deleted on confirm):

```bash
kubectl exec -n <ns> <datastore>-0 -c <datastore> -- tar czf - -C /data appendonlydir dump.rdb > backup.tgz
```

Then restart to force a replay and re-check:

```bash
kubectl delete pod <datastore>-0 -n <ns>      # StatefulSet recreates it; redis replays the AOF on boot
# then re-run dsm-validate.sh --deep <ns>
```
