#!/usr/bin/env bash
# vacuum.sh — Weekly PostgreSQL maintenance
#
# Goals:
#   * Keep dead-tuple bloat in check on very large tables.
#   * Proactively FREEZE tables nearing transaction-id wraparound so the
#     throttled emergency anti-wraparound autovacuum never has to.
#   * Use the host's parallelism (vacuumdb -j + PARALLEL N) instead of
#     vacuuming every table serially.
#   * Be safe to run from cron: single-instance lock, log rotation,
#     non-zero exit on real failures.
#
# Usage:
#   sudo /usr/local/sbin/vacuum.sh
# Cron (e.g. weekly Friday 22:00):
#   0 22 * * 5 /usr/local/sbin/vacuum.sh
#
# Tunables can be overridden via environment, e.g.:
#   JOBS=4 MAINT_MEM=8GB ./vacuum.sh

set -euo pipefail

############################
# Tunables (env-overridable)
############################
JOBS="${JOBS:-6}"                       # parallel tables per DB (vacuumdb -j)
PARALLEL_INDEX="${PARALLEL_INDEX:-8}"   # PARALLEL workers per table for index vacuum
MAINT_MEM="${MAINT_MEM:-16GB}"          # maintenance_work_mem for this run
COST_LIMIT="${COST_LIMIT:-10000}"       # vacuum_cost_limit for this run (NVMe-friendly)
COST_DELAY="${COST_DELAY:-0}"           # vacuum_cost_delay (ms); 0 = unthrottled
LOCK_TIMEOUT="${LOCK_TIMEOUT:-5min}"    # don't wait forever on a stuck lock
FREEZE_AGE_THRESHOLD="${FREEZE_AGE_THRESHOLD:-500000000}"  # xid age that triggers a targeted FREEZE

LOG_DIR="${LOG_DIR:-/var/log/postgres-vacuum}"
LOG_FILE="${LOG_DIR}/vacuum_$(date +%F_%H%M%S).log"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOCK_FILE="${LOCK_FILE:-/var/lock/pg_vacuum.lock}"

# Comma-separated DBs to skip. template0/template1 are always skipped via
# `datistemplate`. The `postgres` DB is intentionally NOT skipped: it also
# accumulates xid age and benefits from periodic vacuuming.
SKIP_DBS="${SKIP_DBS:-}"

############################
# Setup
############################
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"

# Single-instance guard. If the previous run is still going (e.g. a multi-day
# VACUUM), exit cleanly instead of stacking another concurrent run on top.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date -Is)] Another vacuum.sh run is active; exiting." >&2
    exit 0
fi

# Tee all output to the log file.
exec > >(tee -a "$LOG_FILE") 2>&1
chmod 640 "$LOG_FILE" || true

echo "[$(date -Is)] === vacuum.sh starting ==="
echo "[$(date -Is)] JOBS=${JOBS} PARALLEL_INDEX=${PARALLEL_INDEX} MAINT_MEM=${MAINT_MEM} COST_LIMIT=${COST_LIMIT}"

PSQL=(sudo -u postgres psql -X -At -q -P pager=off -v ON_ERROR_STOP=1)
VACUUMDB=(sudo -u postgres vacuumdb)

# These GUCs apply to every connection both psql and vacuumdb make below.
# - statement_timeout=0:    don't time out long VACUUMs.
# - lock_timeout:           bail quickly if blocked rather than queueing.
# - maintenance_work_mem:   make index cleanup fast.
# - vacuum_cost_limit/delay: ignore the throttled global autovacuum config
#                            for this manual run.
export PGOPTIONS="-c statement_timeout=0 -c lock_timeout=${LOCK_TIMEOUT} -c maintenance_work_mem=${MAINT_MEM} -c vacuum_cost_limit=${COST_LIMIT} -c vacuum_cost_delay=${COST_DELAY}"

############################
# Build DB list (most-aged first)
############################
SKIP_WHERE=""
if [[ -n "$SKIP_DBS" ]]; then
    IFS=',' read -r -a _SKIPS <<< "$SKIP_DBS"
    for s in "${_SKIPS[@]}"; do
        s_trimmed="$(echo "$s" | xargs)"
        [[ -z "$s_trimmed" ]] && continue
        # Single-quote-escape to be safe against names with quotes.
        s_escaped="${s_trimmed//\'/\'\'}"
        SKIP_WHERE+=" AND datname <> '${s_escaped}'"
    done
fi

DB_QUERY="
SELECT datname
  FROM pg_database
 WHERE datallowconn
   AND NOT datistemplate
   AND datname NOT IN ('rdsadmin','azure_maintenance')
   ${SKIP_WHERE}
 ORDER BY age(datfrozenxid) DESC, datname;"

mapfile -t DBS < <("${PSQL[@]}" -d postgres -c "$DB_QUERY")

if (( ${#DBS[@]} == 0 )); then
    echo "[$(date -Is)] No databases found to vacuum."
    exit 0
fi

echo "[$(date -Is)] Will process ${#DBS[@]} databases (most-aged first): ${DBS[*]}"

############################
# Main loop
############################
EXIT_CODE=0

for DB in "${DBS[@]}"; do
    DB_ESC="${DB//\'/\'\'}"
    DB_AGE="$("${PSQL[@]}" -d postgres -c "SELECT age(datfrozenxid) FROM pg_database WHERE datname='${DB_ESC}';" || echo "?")"
    echo
    echo "[$(date -Is)] >>> DB=${DB} (datfrozenxid age=${DB_AGE})"

    ###############
    # Phase 1: targeted FREEZE for tables nearing wraparound.
    # Done first, single-table at a time with PARALLEL workers, so the
    # most-at-risk tables are handled before the wider parallel pass.
    ###############
    mapfile -t FREEZE_TABLES < <("${PSQL[@]}" -d "$DB" -c "
        SELECT format('%I.%I', n.nspname, c.relname) || '|' || age(c.relfrozenxid)
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r','m')
           AND n.nspname NOT IN ('pg_catalog','information_schema')
           AND age(c.relfrozenxid) > ${FREEZE_AGE_THRESHOLD}
         ORDER BY age(c.relfrozenxid) DESC;")

    if (( ${#FREEZE_TABLES[@]} > 0 )) && [[ -n "${FREEZE_TABLES[0]:-}" ]]; then
        echo "[$(date -Is)]   ${#FREEZE_TABLES[@]} table(s) above FREEZE_AGE_THRESHOLD=${FREEZE_AGE_THRESHOLD}"
        for entry in "${FREEZE_TABLES[@]}"; do
            [[ -z "$entry" ]] && continue
            T="${entry%%|*}"
            A="${entry##*|}"
            echo "[$(date -Is)]   FREEZE ${T} (age=${A})"
            if ! "${PSQL[@]}" -d "$DB" -c "VACUUM (FREEZE, VERBOSE, PARALLEL ${PARALLEL_INDEX}) ${T};"; then
                echo "[$(date -Is)]   WARN: FREEZE failed on ${T}"
                EXIT_CODE=1
            fi
        done
    else
        echo "[$(date -Is)]   No tables above FREEZE_AGE_THRESHOLD=${FREEZE_AGE_THRESHOLD}"
    fi

    ###############
    # Phase 2: parallel VACUUM ANALYZE across the whole DB.
    # vacuumdb -j N runs N tables concurrently; --parallel M lets each table
    # use M workers for index vacuum. --skip-locked avoids stalling behind
    # long-held locks (we'll pick those tables up next week).
    ###############
    echo "[$(date -Is)]   vacuumdb --analyze -j ${JOBS} --parallel ${PARALLEL_INDEX} -d ${DB}"
    if ! "${VACUUMDB[@]}" -d "$DB" \
            --jobs="$JOBS" \
            --parallel="$PARALLEL_INDEX" \
            --analyze \
            --skip-locked \
            --verbose; then
        echo "[$(date -Is)]   WARN: vacuumdb returned non-zero for ${DB}"
        EXIT_CODE=1
    fi
done

############################
# Log rotation
############################
find "$LOG_DIR" -type f -name 'vacuum_*.log' -mtime +"${LOG_RETENTION_DAYS}" -delete || true

echo
echo "[$(date -Is)] === vacuum.sh done (exit=${EXIT_CODE}) ==="
exit "$EXIT_CODE"
