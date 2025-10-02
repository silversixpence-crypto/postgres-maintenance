#!/usr/bin/env bash
# vacuum_all_dbs.sh
set -euo pipefail

PSQL="sudo -u postgres psql"
LOG_DIR="/var/log/postgres-vacuum"
LOG_FILE="${LOG_DIR}/vacuum_$(date +%F_%H%M%S).log"
SKIP_DBS="postgres"  # e.g. "postgres,db_to_skip"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

IFS=',' read -r -a _SKIPS <<< "$SKIP_DBS"
SKIP_WHERE=''
if (( ${#_SKIPS[@]} > 0 )); then
  for s in "${_SKIPS[@]}"; do
    s_trimmed="$(echo "$s" | xargs)"
    [[ -z "$s_trimmed" ]] && continue
    SKIP_WHERE+=" AND datname <> '$s_trimmed'"
  done
fi

DB_QUERY="
SELECT datname
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
  AND datname NOT IN ('rdsadmin','azure_maintenance')
  ${SKIP_WHERE}
ORDER BY 1;"

echo "[$(date -Is)] Starting VACUUM for all databases" | tee -a "$LOG_FILE"

mapfile -t DBS < <($PSQL -d postgres -At -X -q -c "$DB_QUERY")

if (( ${#DBS[@]} == 0 )); then
  echo "[$(date -Is)] No databases found to vacuum." | tee -a "$LOG_FILE"
  exit 0
fi

for DB in "${DBS[@]}"; do
  echo "[$(date -Is)] >>> Vacuuming database: $DB" | tee -a "$LOG_FILE"
  echo "-- $(date -Is) Begin VACUUM for $DB --" >> "$LOG_FILE"

  # Run psql; if it fails, warn and continue.
  if ! $PSQL -d "$DB" -X -v ON_ERROR_STOP=1 -P pager=off \
        -c '\timing on' \
        -c 'VACUUM (ANALYZE, VERBOSE);' >> "$LOG_FILE" 2>&1; then
    echo "[$(date -Is)] WARNING: VACUUM failed for $DB. See $LOG_FILE" | tee -a "$LOG_FILE"
  else
    echo "-- $(date -Is) End VACUUM for $DB --" >> "$LOG_FILE"
  fi
done

echo "[$(date -Is)] All done. Log: $LOG_FILE"
