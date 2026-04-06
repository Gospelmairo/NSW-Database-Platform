-- ============================================================
-- Real-Time Replication & Interagency Sync Setup
-- Strategy: PostgreSQL Logical Replication + Change Data Capture
-- ============================================================

-- ── Publisher (Primary node) ──────────────────────────────────
-- Run on the PRIMARY database server

-- Enable logical replication (set in postgresql.conf):
--   wal_level = logical
--   max_replication_slots = 10
--   max_wal_senders = 10

-- Create a publication for all shared core tables
CREATE PUBLICATION nsw_core_pub
    FOR TABLE
        core.agencies,
        core.declarations,
        core.sync_log,
        core.platform_users
    WITH (publish = 'insert, update, delete');

-- ── Subscriber (Replica / Agency node) ───────────────────────
-- Run on each AGENCY replica (Customs, Ports, NAFDAC, etc.)

CREATE SUBSCRIPTION nsw_customs_sub
    CONNECTION 'host=primary-db.nsw.gov.ng
                port=5432
                dbname=nsw_platform
                user=repl_user
                password=VAULT_SECRET'
    PUBLICATION nsw_core_pub
    WITH (
        connect        = true,
        enabled        = true,
        copy_data      = true,
        synchronous_commit = 'remote_apply'   -- zero data loss
    );

-- ── Replication Slot Monitoring ───────────────────────────────
-- Detect replication lag before it grows dangerous
CREATE OR REPLACE VIEW core.replication_health AS
SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS lag_size,
    EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp()))
        ::INT AS lag_seconds
FROM pg_replication_slots;

-- ── Sync Status Procedure ─────────────────────────────────────
-- Called by each agency node after processing a sync batch
CREATE OR REPLACE PROCEDURE core.record_sync_result(
    p_source      UUID,
    p_target      UUID,
    p_entity_type TEXT,
    p_entity_id   UUID,
    p_status      TEXT,
    p_records     INT,
    p_error       TEXT DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE core.sync_log
    SET  sync_status   = p_status,
         records_synced = p_records,
         error_detail   = p_error,
         completed_at   = NOW()
    WHERE source_agency = p_source
      AND target_agency = p_target
      AND entity_type   = p_entity_type
      AND entity_id     = p_entity_id
      AND completed_at IS NULL;

    IF NOT FOUND THEN
        INSERT INTO core.sync_log
            (source_agency, target_agency, entity_type, entity_id,
             sync_status, records_synced, error_detail, completed_at)
        VALUES
            (p_source, p_target, p_entity_type, p_entity_id,
             p_status, p_records, p_error, NOW());
    END IF;
END;
$$;

-- ── Conflict Resolution Policy ────────────────────────────────
-- "last writer wins" by updated_at timestamp; used in app layer
-- For agencies that must never overwrite each other, use:
--   UPDATE core.declarations
--   SET ... WHERE declaration_id = $1 AND updated_at <= $2;
-- and raise a conflict error if 0 rows affected.

-- ── Sync Health Alert Function ────────────────────────────────
CREATE OR REPLACE FUNCTION core.check_sync_health()
RETURNS TABLE (
    slot_name   TEXT,
    lag_seconds INT,
    alert       TEXT
) LANGUAGE sql AS $$
    SELECT
        slot_name,
        lag_seconds::INT,
        CASE
            WHEN lag_seconds > 300  THEN 'CRITICAL: >5 min lag'
            WHEN lag_seconds > 60   THEN 'WARNING: >1 min lag'
            ELSE 'OK'
        END
    FROM core.replication_health;
$$;
