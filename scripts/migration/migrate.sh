#!/usr/bin/env bash
# ============================================================
# NSW Platform – Database Migration Runner
# Uses numbered SQL files: V001__description.sql, V002__...
# Safe: checks applied migrations, never replays
# ============================================================
set -euo pipefail

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-nsw_platform}"
DB_USER="${DB_USER:-dba_team}"
MIGRATION_DIR="${MIGRATION_DIR:-$(dirname "$0")/versions}"
SCHEMA_TABLE="core.schema_migrations"

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# Ensure migration tracking table exists
$PSQL -c "
CREATE TABLE IF NOT EXISTS ${SCHEMA_TABLE} (
    version     VARCHAR(10) PRIMARY KEY,
    description TEXT,
    applied_at  TIMESTAMPTZ DEFAULT NOW(),
    checksum    TEXT
);" > /dev/null

apply_migration() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local version
    version=$(echo "$filename" | grep -oE '^V[0-9]+' | tr -d 'V')
    local description
    description=$(echo "$filename" | sed 's/^V[0-9]*__//' | sed 's/\.sql$//' | tr '_' ' ')
    local checksum
    checksum=$(md5sum "$filepath" | awk '{print $1}')

    # Check if already applied
    already_applied=$($PSQL -tAc "
        SELECT COUNT(*) FROM ${SCHEMA_TABLE} WHERE version = '${version}';"
    )

    if [[ "$already_applied" -gt 0 ]]; then
        log "Skipping V${version} – already applied."
        return
    fi

    log "Applying V${version}: ${description}..."
    $PSQL -f "$filepath"

    $PSQL -c "
        INSERT INTO ${SCHEMA_TABLE} (version, description, checksum)
        VALUES ('${version}', '${description}', '${checksum}');" > /dev/null

    log "V${version} applied successfully."
}

log "Running migrations against ${DB_NAME}@${DB_HOST}..."
for migration in "$MIGRATION_DIR"/V*.sql; do
    [[ -f "$migration" ]] || fail "No migration files found in ${MIGRATION_DIR}"
    apply_migration "$migration"
done
log "All migrations complete."
