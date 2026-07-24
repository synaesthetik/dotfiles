#!/usr/bin/env bash
# dsm-validate.sh — bulk validator for DatastoreMigration (kubedb -> cnpg/ot).
#
# Classifies every DSM into GREEN / YELLOW / RED so a batch of migrations can be
# cleared at once. It never annotates/confirms, restarts, or deletes a migration or
# its data. For GREEN migrations it prints the confirm-cleanup command for you to run.
#
# Two migration shapes are handled, auto-detected per DSM:
#   * redis  (kubedb -> opstree): rsync + AOF/RDB boot-log logic (see the redis section).
#   * postgres (kubedb -> cnpg): pg_dump -> PVC -> pg_restore into a CNPG Cluster named after
#     the datastore. No rsync/boot log; ground truth is the CNPG cluster itself — is it healthy,
#     and does the restored database carry the expected schema/size. Validation is read-only
#     psql (SELECT only): database sizes, user-table count, and the largest tables. GREEN when
#     the cluster is healthy and the app db has user tables; YELLOW when the app db is empty
#     (restore may not have landed); RED when a condition is not True or the cluster is unhealthy.
#     --deep swaps the reltuples row estimate for exact COUNT(*). --source-check is redis-only.
#     Only DSMs at phase=AwaitingConfirmation are scored; earlier phases are still in progress.
#
# Default mode is READ-ONLY. rsync is trusted normally. The optional --source-check mode is the
# one exception, and it escalates only SUSPICIOUS migrations (target DBSIZE==0, or the rsync log
# reports a big transfer the target disk doesn't reflect): for those it creates a short-lived pod
# that mounts the SOURCE PVC readOnly, statically scans it, then deletes the pod. Never writes to source.
#
# Verdicts:
#   GREEN  — safe to confirm: all conditions True, rsync Complete, pod Ready, and DBSIZE>0,
#            OR DBSIZE==0 that the boot log explains — redis logged "keys loaded: N" (N>0) with
#            no load errors and dbsize since drained (TTL expiry of cache/ephemeral data), the
#            source was genuinely empty (only expired kubedb_health_checker churn), or every
#            non-HC SET in the incr AOF carried an inline TTL so all keys expired on load.
#   YELLOW — needs a human: DBSIZE==0 AND redis loaded 0 keys at boot yet a durable no-TTL key
#            sits on disk (un-replayed/failed load), redis logged load errors, an rsync/disk mismatch, or
#            (when scanned) the source shows durable keys while the target is empty. Restart the
#            target pod & re-check. Do NOT confirm on YELLOW — cleanup deletes the source PVC.
#   RED    — broken: a condition is not True, rsync not Complete, or target pod not Ready.
#
# Usage:
#   dsm-validate.sh                                  # all namespaces, all types, read-only
#   dsm-validate.sh idp auditlog                     # only these namespaces
#   dsm-validate.sh --type=postgres                  # only postgres DSMs (csv: --type=redis,postgres)
#   dsm-validate.sh --deep greenhouse/foo-kubedb-to-ot   # only this one DSM (ns/name), deep-probed
#   dsm-validate.sh --scan-source=ns/name,ns2/n2     # source-check ONLY these specific DSMs (redis only)
#   dsm-validate.sh --source-check                   # source-check EVERY suspicious DSM (redis only)
#
# Supported types today: redis, postgres. Others are detected and reported UNSUPPORTED (check by
# hand) — adding one is an eval_<type>() + a dispatcher arm + a SUPPORTED_TYPES entry.
#
# Default run flags suspicious DSMs (dbsize 0 / rsync mismatch) but does not touch the source.
# Decide per-DSM whether to escalate, then re-run with --scan-source for the ones you chose.
set -euo pipefail

HC_KEY="kubedb_health_checker"   # kubedb probe key; short-TTL churn, not real data
BASE_RDB_EMPTY_MAX=256           # base.rdb <= this many bytes is treated as empty
AOF_LARGE_BYTES=1073741824       # rsync transfer >= 1GB: replay may outrun the liveness probe

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

DEEP=false              # --deep: exec into target + static on-disk AOF scan (heavy, precise)
SCAN_ALL=false          # --source-check: scan every suspicious DSM (unattended); implies --deep
scan_set=()             # --scan-source=ns/name,...: scan only these specific DSMs (targeted); implies --deep
typefilter=()           # --type=redis,postgres,...: restrict the batch to these datastore types
nsfilter=()

# Datastore types with a validator today. New types (memcached, elasticsearch, ...) are the
# forwards path: add "<type>" here and an eval_<type>() function, and the dispatcher picks it up.
# A detected type not in this list falls through to eval_unsupported (verdict UNSUPPORTED).
SUPPORTED_TYPES="redis postgres"

# Normalize a user-supplied type token to the canonical datastore type used throughout.
norm_type() {
  case "$1" in
    pg|postgre|postgres|postgresql|cnpg) echo postgres ;;
    redis|ot|opstree)                    echo redis ;;
    memcache|memcached)                  echo memcached ;;
    es|elastic|elasticsearch|opensearch) echo elasticsearch ;;
    *)                                   echo "$1" ;;
  esac
}

for a in "$@"; do
  case "$a" in
    --deep) DEEP=true ;;
    --source-check) SCAN_ALL=true; DEEP=true ;;
    --scan-source=*) IFS=',' read -ra _s <<<"${a#*=}"; scan_set+=("${_s[@]}"); DEEP=true ;;
    --type=*) IFS=',' read -ra _t <<<"${a#*=}"; for _x in "${_t[@]}"; do typefilter+=("$(norm_type "$_x")"); done ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) nsfilter+=("$a") ;;
  esac
done

in_scanset() { local n; for n in "${scan_set[@]:-}"; do [ "$n" = "$1" ] && return 0; done; return 1; }
in_typefilter() { [ "${#typefilter[@]}" -eq 0 ] && return 0; local t; for t in "${typefilter[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }

green=(); yellow=(); red=(); err=(); unsupported=(); completed=0; pending=0; filtered=0

# In-pod probe (target): emits KEY=VALUE facts. Reads DBSIZE and single-pass scans the on-disk
# incr AOF for non-health-checker SET keys, split into total (NONHC) vs genuinely durable /
# no-inline-TTL (NONHC_DURABLE). $1 = health-checker key.
read -r -d '' PROBE <<'EOSH' || true
RC="redis-cli --no-auth-warning"
[ -n "${REDIS_PASSWORD:-}" ] && RC="redis-cli -a ${REDIS_PASSWORD} --no-auth-warning"
DBSIZE=$($RC DBSIZE 2>/dev/null | tr -d '\r')
DIR=$($RC CONFIG GET dir 2>/dev/null | tail -1 | tr -d '\r')
AOFDIR="$DIR/appendonlydir"
BASE_BYTES=$(cat "$AOFDIR"/*.base.rdb 2>/dev/null | wc -c | tr -d ' ')
DISK_KB=$(du -sk "$DIR" 2>/dev/null | awk '{print $1}')
# Split non-HC SETs into total vs genuinely durable (no inline TTL). A plain "SET k v" is a
# 3-arg command (*3); "SET k v PXAT ts" / "SET k v EX n" is 4+ args and expires. Tracking each
# command's arity lets a DBSIZE=0 whose keys were all TTL-stamped score GREEN without a source dig.
AOFSTATS=$(cat "$AOFDIR"/*.incr.aof 2>/dev/null | tr -d '\r' | awk -v hc="$1" '
  /^\*[0-9]+$/ { a=substr($0,2)+0; next }
  /^SET$/      { e=2; ar=a; next }
  e>0          { e--; if (e==0 && $0!=hc) { d++; if (ar<=3) dur++ } }
  END          { print (d+0), (dur+0) }')
NONHC=${AOFSTATS%% *}
NONHC_DURABLE=${AOFSTATS##* }
echo "DBSIZE=${DBSIZE:-NA}"
echo "BASE_BYTES=${BASE_BYTES:-NA}"
echo "DISK_KB=${DISK_KB:-NA}"
echo "NONHC=${NONHC:-NA}"
echo "NONHC_DURABLE=${NONHC_DURABLE:-NA}"
EOSH

# In-pod probe (source): the source PVC is mounted readOnly at /src. Static scan only —
# no redis boot (source data must not be modified). Counts durable SET candidates in the
# incr AOF (upper bound) plus keys in the AOF base.rdb via redis-check-rdb. $1 = hc key.
read -r -d '' SRC_PROBE <<'EOSH' || true
AOFDIR="/src/appendonlydir"
DURABLE=$(cat "$AOFDIR"/*.incr.aof 2>/dev/null | tr -d '\r' | awk -v hc="$1" '
  /^\*[0-9]+$/ { a=substr($0,2)+0; next }
  /^SET$/      { e=2; ar=a; next }
  e>0          { e--; if (e==0 && $0!=hc && ar<=3) d++ }
  END          { print d+0 }')
BASEKEYS=0
for f in "$AOFDIR"/*.base.rdb; do
  [ -f "$f" ] || continue
  n=$(redis-check-rdb "$f" 2>/dev/null | sed -n 's/.*\[info\] *\([0-9]*\) keys read.*/\1/p' | tail -1)
  BASEKEYS=$((BASEKEYS + ${n:-0}))
done
echo "SRC_DURABLE=${DURABLE:-0}"
echo "SRC_BASE_KEYS=${BASEKEYS:-0}"
EOSH

# source_scan <ns> <srcpvc> <image>
# Creates a temp pod mounting the source PVC readOnly, runs SRC_PROBE, deletes the pod.
# Emits SRC_DURABLE / SRC_BASE_KEYS / SRC_STATUS (ok|inconclusive). Never fails the script.
source_scan() {
  local ns="$1" pvc="$2" image="$3" pod="dsm-srcscan-$$-${RANDOM}"
  local mani out
  mani=$(cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $ns
  labels:
    app: dsm-srcscan
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: scan
    image: $image
    command: ["sleep", "600"]
    volumeMounts:
    - name: src
      mountPath: /src
      readOnly: true
  volumes:
  - name: src
    persistentVolumeClaim:
      claimName: $pvc
      readOnly: true
YAML
)
  if ! printf '%s\n' "$mani" | kubectl apply -f - >/dev/null 2>&1; then
    echo "SRC_STATUS=inconclusive"; return 0
  fi
  if ! kubectl wait --for=condition=Ready "pod/$pod" -n "$ns" --timeout=180s >/dev/null 2>&1; then
    kubectl delete pod "$pod" -n "$ns" --wait=false >/dev/null 2>&1 || true
    echo "SRC_STATUS=inconclusive"; return 0
  fi
  out=$(kubectl exec -n "$ns" "$pod" -c scan -- sh -c "$SRC_PROBE" _dsm "$HC_KEY" 2>/dev/null || true)
  kubectl delete pod "$pod" -n "$ns" --wait=false >/dev/null 2>&1 || true
  printf '%s\n' "$out"
  echo "SRC_STATUS=ok"
}

mapfile -t rows < <(kubectl get dsm --all-namespaces -o json | jq -r '
  .items[] | [
    .metadata.namespace, .metadata.name, .spec.datastoreRef.name, (.status.phase // "Unknown"),
    ([.status.conditions[]? | select(.status=="True")] | length),
    ([.status.conditions[]?] | length),
    (
      # Datastore type, derived from the DSM. Prefer explicit signals (target provider, the
      # per-type status block); fall back to the datastore name. Add new arms as validators land.
      if   (.spec.targetProvider=="cnpg") or (.status.postgres!=null) then "postgres"
      elif (.status.redis!=null) then "redis"
      elif (.status.memcached!=null) then "memcached"
      elif (.status.elasticsearch!=null) then "elasticsearch"
      else ((.spec.datastoreRef.name // .metadata.name // "") |
        if   test("postgres|cnpg|-pg-") then "postgres"
        elif test("redis")              then "redis"
        elif test("memcache")           then "memcached"
        elif test("elastic|opensearch") then "elasticsearch"
        else "unknown" end)
      end
    ),
    (.status.redis.rsyncJobName // ""),
    (.status.redis.sourcePVCName // ""),
    (.status.postgres.sourcePVCName // "")
  ] | @tsv')

[ "${#rows[@]}" -eq 0 ] && { echo "No DatastoreMigrations found."; exit 0; }

in_filter() { [ "${#nsfilter[@]}" -eq 0 ] && return 0; local n; for n in "${nsfilter[@]}"; do { [ "$n" = "$1" ] || [ "$n" = "$1/$2" ]; } && return 0; done; return 1; }

# eval_redis <ns> <name> <ds> <phase> <ctrue> <ctot> <rsync> <srcpvc>
# Evaluates one redis (kubedb -> opstree) DSM and prints its findings, ending with a
# machine-readable RESULT=<verdict> line. Called inside a command-substitution subshell so a
# fatal error (unbound var, aborted probe) is contained to this one DSM and never aborts the batch.
eval_redis() {
  local ns="$1" name="$2" ds="$3" phase="$4" ctrue="$5" ctot="$6" rsync="$7" srcpvc="$8"
  local verdict="GREEN"; local notes=()

  # conditions
  if [ "$ctot" -eq 0 ] || [ "$ctrue" -ne "$ctot" ]; then
    verdict="RED"; notes+=("conditions ${ctrue}/${ctot} True")
  fi

  # rsync job — status plus the "total size is N" the transfer reported, for the mismatch check
  rstat="?"; rsync_bytes=""
  if [ -n "$rsync" ]; then
    rstat=$(kubectl get job -n "$ns" "$rsync" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    [ "$rstat" = "True" ] || { verdict="RED"; notes+=("rsync job not Complete ($rsync)"); }
    rsync_bytes=$(kubectl logs -n "$ns" "job/$rsync" 2>/dev/null | grep -oE 'total size is [0-9,]+' | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || true)
  else
    notes+=("no rsyncJobName in status")
  fi

  # target pod probe
  pod="${ds}-0"; ctr="$ds"
  ready=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$ready" != "True" ]; then
    verdict="RED"; notes+=("target pod $pod not Ready")
    echo "  phase=$phase conditions=${ctrue}/${ctot} rsync=$rstat rsync_sent=${rsync_bytes:-?}B pod=notReady"
    # A crashlooping target has TWO causes with opposite fixes. Read lastState to disambiguate
    # BEFORE guessing — a multi-GB rsync alone does NOT imply the replay crashloop.
    last_reason=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
    last_exit=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)
    pod_mem_limit=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
    if [ "$last_reason" = "OOMKilled" ] || [ "$last_exit" = "137" ]; then
      notes+=("OOMKilled (reason=${last_reason:-?} exit=${last_exit:-?}, limit=${pod_mem_limit:-?}): dataset too big for the memory limit — NOT the replay crashloop. Check boot log 'RDB memory usage when created N Mb' vs the limit. BGREWRITEAOF/wider probes do NOT help (they shrink disk/replay-time, not in-memory footprint). Fix: raise memory at the Datastore CR (top of Datastore->Redis CR->STS chain; the CR/STS get reverted): kubectl patch datastore.datastore.greenhouse.io ${ds} -n ${ns} --type merge -p '{\"spec\":{\"k8sRedis\":{\"resources\":{\"limits\":{\"memory\":\"2Gi\"}}}}}'  then 'kubectl delete pod ${pod} -n ${ns}' to unstick the deadlocked STS rollout (RollingUpdate won't roll a never-Ready pod).")
    elif [ "$last_reason" = "Completed" ] || [ "$last_exit" = "0" ] || { [ -n "$rsync_bytes" ] && [ "$rsync_bytes" -ge "$AOF_LARGE_BYTES" ] 2>/dev/null; }; then
      notes+=("possible AOF-replay-vs-liveness crashloop (reason=${last_reason:-?} exit=${last_exit:-?}, rsync ${rsync_bytes:-?}B): redis may be killed mid-replay before it can answer PING. Confirm via 'Received shutdown signal during loading' in logs + lastState reason=Completed exit=0 (a graceful SIGTERM; OOMKilled/137 would be the memory case above). Fix: widen initialDelaySeconds/failureThreshold on the opstree Redis CR (redis.redis.redis.opstreelabs.in, NOT the STS) so it survives one full replay; it then auto-compacts the AOF. Prevent: pre-compact the source (BGREWRITEAOF/ship RDB) before migrating.")
    fi
  else
    # Boot log is the ground truth for whether the migrated data actually LOADED. redis logs
    # "Done loading RDB, keys loaded: N" and "Ready to accept connections". A later DBSIZE of 0
    # with keys_loaded>0 is benign TTL expiry (cache/ephemeral); keys_loaded==0 with data on
    # disk is a real un-replayed/failed load. DBSIZE alone cannot tell these apart. This is the
    # only signal the default (light-touch) path needs — no exec, no on-disk scan.
    klog=$(kubectl logs -n "$ns" "$pod" -c "$ctr" 2>/dev/null || true)
    kloaded=$(grep -oE 'keys loaded: [0-9]+' <<<"$klog" | tail -1 | grep -oE '[0-9]+$' || true)
    loaderr=$(grep -ciE 'Bad file format|Internal error in RDB|Short read|error loading|corrupt' <<<"$klog" 2>/dev/null || echo 0)
  fi

  if [ "$ready" = "True" ] && ! $DEEP; then
    # LIGHT-TOUCH (default): two log reads, no exec. Boot log says whether data replayed; rsync
    # "total size" is context. keys loaded>0 with no errors = loaded (GREEN). keys loaded 0 means
    # the base RDB was empty, so any real data arrived via the incr AOF — which light-touch does
    # not scan — so we can't tell an empty source from a failed load: escalate to --deep.
    echo "  phase=$phase conditions=${ctrue}/${ctot} rsync=$rstat pod=Ready loaded_at_boot=${kloaded:-?} rsync_sent=${rsync_bytes:-?}B  [light]"
    if [ "$verdict" != "RED" ]; then
      if [ "${loaderr:-0}" -gt 0 ] 2>/dev/null; then
        verdict="YELLOW"; notes+=("redis logged AOF/RDB load errors at boot — investigate (or re-run --deep $ns) before confirming")
      elif [ -n "$kloaded" ] && [ "$kloaded" -gt 0 ] 2>/dev/null; then
        notes+=("redis loaded $kloaded keys at boot with no errors — data replayed (a later DBSIZE of 0 would be benign TTL expiry)")
      else
        verdict="YELLOW"
        notes+=("boot log shows keys loaded ${kloaded:-none} (empty base RDB); data, if any, is in the unscanned incr AOF (rsync sent ${rsync_bytes:-?}B) — re-run with --deep on this DSM to resolve")
        echo "  light-touch inconclusive — re-run: dsm-validate.sh --deep $ns   (or --scan-source=$ns/$name)"
      fi
    fi
  elif [ "$ready" = "True" ]; then
    facts=$(kubectl exec -n "$ns" "$pod" -c "$ctr" -- sh -c "$PROBE" _dsm "$HC_KEY" 2>/dev/null || true)
    dbsize=$(sed -n 's/^DBSIZE=//p' <<<"$facts"); dbsize=${dbsize:-NA}
    base=$(sed -n 's/^BASE_BYTES=//p' <<<"$facts"); base=${base:-NA}
    diskkb=$(sed -n 's/^DISK_KB=//p' <<<"$facts"); diskkb=${diskkb:-NA}
    nonhc=$(sed -n 's/^NONHC=//p' <<<"$facts"); nonhc=${nonhc:-NA}
    nonhc_durable=$(sed -n 's/^NONHC_DURABLE=//p' <<<"$facts"); nonhc_durable=${nonhc_durable:-NA}
    echo "  phase=$phase conditions=${ctrue}/${ctot} rsync=$rstat pod=Ready dbsize=$dbsize loaded_at_boot=${kloaded:-?} base_rdb=${base}B disk=${diskkb}KB rsync_sent=${rsync_bytes:-?}B nonHC_sets=$nonhc nonHC_durable=$nonhc_durable"

    # rsync-vs-reality: rsync reported a substantial transfer but the target's redis dir is far
    # smaller -> data may not have landed. BUT redis rewrites/compacts the AOF after loading (an
    # 8GB churned AOF becomes KB), so a small disk is normal once the data loaded. Only meaningful
    # when there's NO evidence of a successful load (dbsize==0 AND keys loaded==0).
    loaded_ok=false
    { [ "$dbsize" != "NA" ] && [ "$dbsize" -gt 0 ] 2>/dev/null; } && loaded_ok=true
    { [ -n "$kloaded" ] && [ "$kloaded" -gt 0 ] 2>/dev/null; } && loaded_ok=true
    mismatch=false
    if ! $loaded_ok && [ -n "$rsync_bytes" ] && [ "$diskkb" != "NA" ] && [ "$rsync_bytes" -gt 1048576 ] 2>/dev/null; then
      disk_bytes=$(( diskkb * 1024 ))
      if [ "$disk_bytes" -lt $(( rsync_bytes / 2 )) ] 2>/dev/null; then
        mismatch=true
        [ "$verdict" != "RED" ] && verdict="YELLOW"
        notes+=("rsync sent ${rsync_bytes}B but target disk holds ~${disk_bytes}B and redis loaded no keys — data may not have landed")
      fi
    fi

    if [ "$verdict" != "RED" ]; then
      if [ "$dbsize" = "NA" ]; then
        verdict="YELLOW"; notes+=("could not read DBSIZE — check auth/container")
      elif [ "$dbsize" -gt 0 ] 2>/dev/null; then
        : # data loaded -> GREEN
      else
        # DBSIZE==0. Ask the boot log what redis actually loaded before judging.
        if [ "$loaderr" -gt 0 ] 2>/dev/null; then
          verdict="YELLOW"; notes+=("DBSIZE=0 and redis logged AOF/RDB load errors — investigate before confirming")
        elif [ -n "$kloaded" ] && [ "$kloaded" -gt 0 ] 2>/dev/null; then
          notes+=("0 keys is valid: redis loaded $kloaded keys at boot with no errors; dbsize now 0 = TTL expiry of ephemeral/cache data")
        elif [ "$base" != "NA" ] && [ "$base" -le "$BASE_RDB_EMPTY_MAX" ] 2>/dev/null && [ "${nonhc_durable:-NA}" = "0" ]; then
          # Base RDB empty and no non-HC SET carries a durable (no-TTL) value: every real key had
          # an inline expiry. Source stopped -> all PXAT in the past -> keys expire on load -> 0.
          if [ "$nonhc" = "0" ]; then
            notes+=("0 keys is valid: source empty (only expired ${HC_KEY} churn)")
          else
            notes+=("0 keys is valid: all $nonhc non-HC SET(s) carry an inline TTL; source stopped -> expired on load")
          fi
        else
          verdict="YELLOW"
          notes+=("DBSIZE=0, redis loaded ${kloaded:-0} keys at boot, but ${nonhc_durable} durable no-TTL key(s) on disk (nonHC_sets=$nonhc base_rdb=${base}B) — restart pod & re-check before confirming")
        fi
      fi
    fi

    # Source-side second opinion (creates + deletes a temp read-only pod). Only escalated for
    # SUSPICIOUS migrations — target empty or an rsync/disk mismatch. Otherwise we trust rsync.
    # A migration is "suspicious" only once the boot-log-aware classifier lands on YELLOW —
    # a DBSIZE=0 that the boot log explains as TTL expiry is GREEN and needs no source dig.
    suspicious=false
    [ "$verdict" = "YELLOW" ] && suspicious=true
    scan_this=false
    if $suspicious; then
      { $SCAN_ALL || in_scanset "$ns/$name"; } && scan_this=true
      $scan_this || echo "  suspicious — source-check available: re-run with --scan-source=$ns/$name"
    fi
    if $scan_this && [ "$verdict" != "RED" ] && [ -n "$srcpvc" ]; then
      image=$(kubectl get pod -n "$ns" "$pod" -o jsonpath="{.spec.containers[?(@.name==\"$ctr\")].image}" 2>/dev/null || true)
      if [ -z "$image" ]; then
        echo "  source-check: skipped (could not resolve target image)"
      else
        src=$(source_scan "$ns" "$srcpvc" "$image")
        src_status=$(sed -n 's/^SRC_STATUS=//p' <<<"$src")
        if [ "$src_status" != "ok" ]; then
          echo "  source-check: inconclusive (could not mount/scan source PVC $srcpvc)"
          notes+=("source-check inconclusive — verify manually before confirming")
        else
          src_durable=$(sed -n 's/^SRC_DURABLE=//p' <<<"$src"); src_durable=${src_durable:-0}
          src_basekeys=$(sed -n 's/^SRC_BASE_KEYS=//p' <<<"$src"); src_basekeys=${src_basekeys:-0}
          src_signal=$(( src_durable + src_basekeys ))
          echo "  source-check: src_durable=$src_durable src_base_keys=$src_basekeys (upper-bound ~$src_signal) vs target dbsize=$dbsize"
          if [ "$src_signal" -gt 0 ] 2>/dev/null && { [ "$dbsize" = "0" ] || $mismatch; }; then
            verdict="YELLOW"; notes+=("source shows ~$src_signal durable keys but target looks empty — do not confirm")
          elif [ "$src_signal" -eq 0 ] 2>/dev/null; then
            notes+=("source-check confirms source had 0 durable keys — target empty is correct")
          fi
        fi
      fi
    fi
  fi

  printf '  VERDICT: %s\n' "$verdict"
  ((${#notes[@]})) && for n in "${notes[@]}"; do echo "    - $n"; done
  if [ "$verdict" = "GREEN" ]; then
    echo "    confirm: kubectl annotate DatastoreMigration -n $ns $name datastore.greenhouse.io/migration-confirm-cleanup=true"
  fi
  echo "RESULT=$verdict"
}

# eval_postgres <ns> <name> <ds> <phase> <ctrue> <ctot> <srcpvc>
# Evaluates one postgres (kubedb -> cnpg) DSM. The migration is pg_dump (source) -> PVC ->
# pg_restore into a CNPG Cluster named after the datastore ($ds). There is no rsync or redis
# boot log; the dump/restore Jobs are often GC'd by the time this runs. Ground truth for "did
# the data land" is the CNPG cluster itself: is it healthy, and does the restored database
# carry the expected schema/size. Read-only — only SELECTs via psql on the primary.
eval_postgres() {
  local ns="$1" name="$2" ds="$3" phase="$4" ctrue="$5" ctot="$6" srcpvc="$7"
  local verdict="GREEN"; local notes=()
  local cl clphase inst ready primary
  local dbrows appdb tcount appsize tbls t rows sz c

  if [ "$ctot" -eq 0 ] || [ "$ctrue" -ne "$ctot" ]; then
    verdict="RED"; notes+=("conditions ${ctrue}/${ctot} True")
  fi

  # CNPG cluster (name == datastore name). Healthy = phase says so AND readyInstances==instances.
  cl=$(kubectl get cluster.postgresql.cnpg.io "$ds" -n "$ns" -o json 2>/dev/null || true)
  if [ -z "$cl" ]; then
    verdict="RED"; notes+=("CNPG cluster $ds not found in ns $ns")
    echo "  phase=$phase conditions=${ctrue}/${ctot} cluster=MISSING"
    printf '  VERDICT: %s\n' "$verdict"
    for n in "${notes[@]}"; do echo "    - $n"; done
    echo "RESULT=$verdict"; return
  fi
  clphase=$(jq -r '.status.phase // "?"' <<<"$cl")
  inst=$(jq -r '.spec.instances // 1' <<<"$cl")
  ready=$(jq -r '.status.readyInstances // 0' <<<"$cl")
  primary=$(jq -r '.status.currentPrimary // ""' <<<"$cl")
  if [ "${ready:-0}" -lt "${inst:-1}" ] 2>/dev/null || [ -z "$primary" ]; then
    verdict="RED"; notes+=("CNPG cluster not healthy (phase=\"$clphase\" ready=${ready}/${inst})")
  fi

  echo "  phase=$phase conditions=${ctrue}/${ctot} cluster=\"$clphase\" ready=${ready}/${inst} primary=${primary:-none}"

  # Data probe (read-only SELECTs) — only if there's a reachable primary. Even a RED cluster is
  # worth probing if a primary exists, so the operator can see what (if anything) landed.
  if [ -n "$primary" ]; then
    # Non-system databases with size (biggest first); the app db is the largest of these.
    dbrows=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -tA -F'|' -c \
      "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY pg_database_size(datname) DESC;" 2>/dev/null | tr -d '\r' || true)
    if [ -z "$dbrows" ]; then
      [ "$verdict" != "RED" ] && verdict="YELLOW"
      notes+=("no application database on target (only system dbs) — restore may not have landed; do not confirm")
      echo "  databases: (none besides system)"
    else
      echo "  databases: $(awk -F'|' '{printf "%s%s (%s)", (NR>1?", ":""), $1, $2} END{print ""}' <<<"$dbrows")"
      appdb=$(head -1 <<<"$dbrows" | cut -d'|' -f1)
      tcount=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -d "$appdb" -tA -c \
        "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema');" 2>/dev/null | tr -d '\r' || true)
      tcount=${tcount:-0}
      appsize=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -d "$appdb" -tA -c \
        "SELECT pg_size_pretty(pg_database_size('$appdb'));" 2>/dev/null | tr -d '\r' || true)
      echo "  app db '$appdb': ${tcount} user tables, ${appsize:-?}"
      if [ "${tcount:-0}" -eq 0 ] 2>/dev/null; then
        [ "$verdict" != "RED" ] && verdict="YELLOW"
        notes+=("app db '$appdb' has 0 user tables — restore may not have loaded; do not confirm")
      elif $DEEP; then
        # --deep: exact COUNT(*) for the largest tables (heavier; iterates per table).
        tbls=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -d "$appdb" -tA -F'|' -c \
          "SELECT n.nspname||'.'||c.relname, pg_size_pretty(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 10;" 2>/dev/null | tr -d '\r' || true)
        while IFS='|' read -r t sz; do
          [ -z "$t" ] && continue
          c=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -d "$appdb" -tA -c "SELECT count(*) FROM \"${t%%.*}\".\"${t#*.}\";" 2>/dev/null | tr -d '\r' || true)
          echo "    $t  ${c:-?} rows  ${sz}"
        done <<<"$tbls"
        [ "$tcount" -gt 10 ] 2>/dev/null && echo "    ... ($((tcount-10)) more tables)"
      else
        # Default: reltuples estimate (cheap, from the catalog; -1 means never analyzed).
        tbls=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -d "$appdb" -tA -F'|' -c \
          "SELECT n.nspname||'.'||c.relname, c.reltuples::bigint, pg_size_pretty(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 10;" 2>/dev/null | tr -d '\r' || true)
        while IFS='|' read -r t rows sz; do
          [ -z "$t" ] && continue
          [ "$rows" = "-1" ] && rows="?"
          echo "    $t  ~${rows} rows  ${sz}"
        done <<<"$tbls"
        [ "$tcount" -gt 10 ] 2>/dev/null && echo "    ... ($((tcount-10)) more tables)"
      fi
    fi
  fi

  if { $SCAN_ALL || in_scanset "$ns/$name"; } && [ -n "$srcpvc" ]; then
    echo "  note: --source-check/--scan-source is redis-only; validated the target cluster only"
  fi

  printf '  VERDICT: %s\n' "$verdict"
  ((${#notes[@]})) && for n in "${notes[@]}"; do echo "    - $n"; done
  if [ "$verdict" = "GREEN" ]; then
    echo "    confirm: kubectl annotate DatastoreMigration -n $ns $name datastore.greenhouse.io/migration-confirm-cleanup=true"
  fi
  echo "RESULT=$verdict"
}

# eval_unsupported <ns> <name> <phase> <kind>
# A DSM whose datastore type has no validator yet. Never GREEN — the operator must check it
# by hand. This is the graceful landing spot until an eval_<kind>() is added for that type.
eval_unsupported() {
  local ns="$1" name="$2" phase="$3" kind="$4"
  echo "  phase=$phase type=$kind — no validator implemented for '$kind' yet"
  printf '  VERDICT: %s\n' "UNSUPPORTED"
  echo "    - dsm-validate has no '$kind' evaluator (supported: ${SUPPORTED_TYPES}); inspect manually — NOT auto-safe to confirm"
  echo "RESULT=UNSUPPORTED"
}

# eval_dsm — dispatch to the per-type evaluator based on <kind> (arg 7). To add a type, drop in
# an eval_<type>() and a case arm here, and list it in SUPPORTED_TYPES.
# args: <ns> <name> <ds> <phase> <ctrue> <ctot> <kind> <rsync> <redis_srcpvc> <pg_srcpvc>
eval_dsm() {
  case "$7" in
    postgres) eval_postgres "$1" "$2" "$3" "$4" "$5" "$6" "${10}" ;;
    redis)    eval_redis    "$1" "$2" "$3" "$4" "$5" "$6" "$8" "$9" ;;
    *)        eval_unsupported "$1" "$2" "$4" "$7" ;;
  esac
}

for row in "${rows[@]}"; do
  IFS=$'\t' read -r ns name ds phase ctrue ctot kind rsync redis_srcpvc pg_srcpvc <<<"$row"
  in_filter "$ns" "$name" || continue

  # --type filter: restrict the batch to the requested datastore type(s). Skip others silently.
  if ! in_typefilter "$kind"; then filtered=$((filtered + 1)); continue; fi

  # Completed DSMs are already confirmed — nothing to validate. Skip silently
  # (count them for the summary) so the output is only the actionable ones.
  if [ "$phase" = "Completed" ]; then
    completed=$((completed + 1))
    continue
  fi

  # Only AwaitingConfirmation is confirmable. Anything else (PreflightComplete, mid-migration)
  # is still in progress — not broken, but not ready. Note it briefly and don't score it.
  if [ "$phase" != "AwaitingConfirmation" ]; then
    pending=$((pending + 1))
    echo "──────────────────────────────────────────────"
    echo "$ns/$name  (datastore=$ds)  [$kind]"
    echo "  phase=$phase — migration in progress; not yet at AwaitingConfirmation, nothing to confirm"
    continue
  fi

  echo "──────────────────────────────────────────────"
  echo "$ns/$name  (datastore=$ds)  [$kind]"

  # Fault-isolation: evaluate in a subshell so a fatal error in one DSM (unbound var, an
  # aborted probe) degrades to ERROR for that DSM only — the batch keeps going. stderr still
  # surfaces; a missing RESULT line means the eval aborted.
  out=$(eval_dsm "$ns" "$name" "$ds" "$phase" "$ctrue" "$ctot" "$kind" "$rsync" "$redis_srcpvc" "$pg_srcpvc" 2>&1) || true
  sed '/^RESULT=/d' <<<"$out"
  verdict=$(sed -n 's/^RESULT=//p' <<<"$out" | tail -1)

  case "${verdict:-ERROR}" in
    GREEN)       green+=("$ns/$name") ;;
    YELLOW)      yellow+=("$ns/$name") ;;
    RED)         red+=("$ns/$name") ;;
    UNSUPPORTED) unsupported+=("$ns/$name ($kind)") ;;
    *)           err+=("$ns/$name"); echo "  VERDICT: ERROR — evaluation aborted (see message above); NOT safe to confirm" ;;
  esac
done

echo "══════════════════════════════════════════════"
echo "SUMMARY: ${#green[@]} GREEN  ${#yellow[@]} YELLOW  ${#red[@]} RED  ${#unsupported[@]} UNSUPPORTED  ${#err[@]} ERROR  (${pending} in progress, ${completed} Completed skipped, ${filtered} filtered by --type)"
[ "${#yellow[@]}" -gt 0 ]      && printf '  YELLOW (needs human): %s\n' "${yellow[*]}"
[ "${#red[@]}" -gt 0 ]         && printf '  RED (broken):         %s\n' "${red[*]}"
[ "${#unsupported[@]}" -gt 0 ] && printf '  UNSUPPORTED (no validator; check by hand): %s\n' "${unsupported[*]}"
[ "${#err[@]}" -gt 0 ]         && printf '  ERROR (eval failed):  %s\n' "${err[*]}"
exit 0
