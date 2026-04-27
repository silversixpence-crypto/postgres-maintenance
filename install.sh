#!/usr/bin/env bash
# install.sh — Install or update vacuum.sh on a PostgreSQL host.
#
# Usage (run as root on each Postgres host):
#   curl -fsSL https://raw.githubusercontent.com/silversixpence-crypto/postgres-maintenance/main/install.sh | sudo bash
#
# Pin to a specific commit/tag for reproducibility:
#   REF=v1.0.0 curl -fsSL "https://raw.githubusercontent.com/silversixpence-crypto/postgres-maintenance/${REF}/install.sh" | sudo REF="$REF" bash
#
# Override defaults:
#   CRON_SCHEDULE='30 2 * * 6' INSTALL_PATH=/opt/sbin/vacuum.sh ./install.sh
#
# Re-running the script updates vacuum.sh in place and refreshes the cron
# entry. Safe to run repeatedly.

set -euo pipefail

REF="${REF:-main}"
REPO="${REPO:-silversixpence-crypto/postgres-maintenance}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${REF}}"

INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/vacuum.sh}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 22 * * 5}"  # Friday 22:00 by default
CRON_USER="${CRON_USER:-root}"
CRON_TAG="# postgres-maintenance:vacuum.sh (managed by install.sh)"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: install.sh must be run as root (use sudo)." >&2
    exit 1
fi

# Need at least one of curl or wget to fetch.
if command -v curl >/dev/null 2>&1; then
    FETCH=(curl -fsSL --retry 3 --retry-delay 2)
elif command -v wget >/dev/null 2>&1; then
    FETCH=(wget -qO-)
else
    echo "ERROR: need curl or wget installed." >&2
    exit 1
fi

echo "[install] Repo:    ${REPO}"
echo "[install] Ref:     ${REF}"
echo "[install] Target:  ${INSTALL_PATH}"
echo "[install] Cron:    ${CRON_SCHEDULE}  (user=${CRON_USER})"

# Sanity: postgres should be reachable. Warn but don't fail (script may be
# pre-staged before the cluster is created).
if ! command -v psql >/dev/null 2>&1; then
    echo "[install] WARN: psql not found in PATH; vacuum.sh expects 'sudo -u postgres psql' to work." >&2
fi
if ! command -v vacuumdb >/dev/null 2>&1; then
    echo "[install] WARN: vacuumdb not found in PATH; vacuum.sh requires it." >&2
fi

# Fetch vacuum.sh
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
URL="${RAW_BASE}/vacuum.sh"
echo "[install] Fetching ${URL}"
"${FETCH[@]}" "$URL" > "$TMP"

# Basic sanity check on what we downloaded
if ! head -1 "$TMP" | grep -q '^#!.*bash'; then
    echo "ERROR: downloaded file does not look like a bash script:" >&2
    head -3 "$TMP" >&2
    exit 1
fi
if ! bash -n "$TMP"; then
    echo "ERROR: downloaded vacuum.sh failed bash syntax check." >&2
    exit 1
fi

# Install atomically
install -d -m 0755 "$(dirname "$INSTALL_PATH")"
install -m 0750 -o root -g root "$TMP" "$INSTALL_PATH"
echo "[install] Installed ${INSTALL_PATH} ($(wc -c < "$INSTALL_PATH") bytes)"

# Update crontab for CRON_USER, removing any prior managed entry or the
# legacy curl|bash line, then appending the current one.
NEW_CRON_LINE="${CRON_SCHEDULE} ${INSTALL_PATH}  ${CRON_TAG}"

CURRENT="$(crontab -u "$CRON_USER" -l 2>/dev/null || true)"
FILTERED="$(printf '%s\n' "$CURRENT" \
    | grep -v -F "$CRON_TAG" \
    | grep -v -E 'postgres-maintenance.*vacuum\.sh' \
    | grep -v -E '/usr/local/sbin/vacuum\.sh' \
    || true)"

# Drop any trailing blank lines, then append our entry.
{
    printf '%s\n' "$FILTERED" | sed -e '/./,$!d' | awk 'NF{p=1} p'
    printf '%s\n' "$NEW_CRON_LINE"
} | crontab -u "$CRON_USER" -

echo "[install] Cron entry for ${CRON_USER}:"
crontab -u "$CRON_USER" -l | grep -F "$CRON_TAG" || true

echo "[install] Done. To run now: sudo ${INSTALL_PATH}"
