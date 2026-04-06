#!/usr/bin/env bash
# ============================================================
# NSW Platform – Automated Backup Script
# Strategy:
#   - Full base backup (weekly, via pg_basebackup)
#   - WAL archiving (continuous, point-in-time recovery)
#   - Logical dump of critical schemas (nightly, pg_dump)
# Retention: 30 days full backups, 7 days WAL
# ============================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-nsw_platform}"
DB_USER="${DB_USER:-backup_user}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup/nsw}"
S3_BUCKET="${S3_BUCKET:-s3://nsw-db-backups}"
RETENTION_DAYS=30
WAL_RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/nsw_backup_${TIMESTAMP}.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────
command -v pg_basebackup >/dev/null || fail "pg_basebackup not found"
command -v pg_dump       >/dev/null || fail "pg_dump not found"
command -v aws           >/dev/null || fail "aws cli not found"
mkdir -p "${BACKUP_ROOT}/base" "${BACKUP_ROOT}/logical" "${BACKUP_ROOT}/wal"

# ── 1. Base Backup (runs weekly via cron) ─────────────────────
run_base_backup() {
    log "Starting base backup..."
    local dest="${BACKUP_ROOT}/base/base_${TIMESTAMP}"
    pg_basebackup \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -D "$dest" \
        --format=tar \
        --compress=9 \
        --checkpoint=fast \
        --wal-method=stream \
        --progress \
        --label="nsw_base_${TIMESTAMP}" \
        2>>"$LOG_FILE"
    log "Base backup complete: ${dest}"

    # Upload to S3 with server-side encryption
    aws s3 sync "$dest" "${S3_BUCKET}/base/base_${TIMESTAMP}/" \
        --sse aws:kms \
        --storage-class STANDARD_IA \
        >> "$LOG_FILE" 2>&1
    log "Base backup uploaded to S3."
}

# ── 2. Logical Dump (runs nightly via cron) ───────────────────
run_logical_dump() {
    log "Starting logical dump..."
    local dest="${BACKUP_ROOT}/logical/dump_${TIMESTAMP}.dump"
    pg_dump \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=custom \
        --compress=9 \
        --no-password \
        -f "$dest" \
        2>>"$LOG_FILE"
    log "Logical dump complete: ${dest}"

    aws s3 cp "$dest" "${S3_BUCKET}/logical/dump_${TIMESTAMP}.dump" \
        --sse aws:kms \
        >> "$LOG_FILE" 2>&1
    log "Logical dump uploaded to S3."
}

# ── 3. Verify Backup Integrity ────────────────────────────────
verify_backup() {
    local dump_file="$1"
    log "Verifying backup integrity: ${dump_file}"
    pg_restore --list "$dump_file" > /dev/null 2>&1 \
        && log "Verification PASSED" \
        || fail "Verification FAILED for ${dump_file}"
}

# ── 4. Prune Old Backups ──────────────────────────────────────
prune_old_backups() {
    log "Pruning backups older than ${RETENTION_DAYS} days..."
    find "${BACKUP_ROOT}/base"    -mtime +"$RETENTION_DAYS" -type d -exec rm -rf {} + 2>/dev/null || true
    find "${BACKUP_ROOT}/logical" -mtime +"$RETENTION_DAYS" -type f -delete 2>/dev/null || true
    # S3 lifecycle rules handle remote pruning (set in terraform/s3.tf)
    log "Pruning complete."
}

# ── 5. Alert on Failure ───────────────────────────────────────
notify_failure() {
    local msg="NSW DB Backup FAILED at ${TIMESTAMP}. Check ${LOG_FILE}"
    # Swap with your alerting tool (PagerDuty, SNS, Slack, etc.)
    aws sns publish \
        --topic-arn "${SNS_ALERT_TOPIC:-arn:aws:sns:af-south-1:ACCT:nsw-db-alerts}" \
        --message "$msg" \
        || log "WARNING: Could not send SNS alert."
}

trap 'notify_failure' ERR

# ── Main ──────────────────────────────────────────────────────
MODE="${1:-logical}"   # pass 'base' for weekly full backup
case "$MODE" in
    base)
        run_base_backup
        prune_old_backups
        ;;
    logical)
        run_logical_dump
        latest="${BACKUP_ROOT}/logical/dump_${TIMESTAMP}.dump"
        verify_backup "$latest"
        prune_old_backups
        ;;
    *)
        fail "Unknown mode: $MODE. Use 'base' or 'logical'."
        ;;
esac

log "Backup job finished successfully (mode=${MODE})."
