-- ============================================================
-- NSW Platform – Performance Tuning & EXPLAIN ANALYZE
-- Run each section in pgAdmin Query Tool one at a time
-- ============================================================

-- ============================================================
-- SECTION 1: EXPLAIN ANALYZE – See how queries actually run
-- ============================================================

-- 1a. Basic declaration lookup by status
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT declaration_no, declaration_type, status, payload
FROM core.declarations
WHERE status = 'PENDING'
ORDER BY created_at DESC
LIMIT 20;

-- 1b. Agency join query (common in reports)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    a.agency_code,
    d.declaration_no,
    d.declaration_type,
    d.status,
    d.payload->>'cargo'       AS cargo,
    d.payload->>'invoice_usd' AS invoice_usd
FROM core.declarations d
JOIN core.agencies a ON a.agency_id = d.origin_agency
WHERE a.agency_code = 'CUSTOMS'
  AND d.status = 'PENDING'
ORDER BY d.created_at DESC;

-- 1c. JSONB payload search (common filtering pattern)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT declaration_no, payload
FROM core.declarations
WHERE payload->>'country' = 'CN'
  AND (payload->>'invoice_usd')::numeric > 100000;

-- 1d. Audit log lookup by resource
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT event_time, action, old_values, new_values
FROM audit.event_log
WHERE resource_table = 'declarations'
ORDER BY event_time DESC
LIMIT 50;

-- ============================================================
-- SECTION 2: MISSING INDEX DETECTION
-- ============================================================

-- Find tables with sequential scans (should be using indexes)
SELECT
    schemaname,
    relname                                         AS table_name,
    seq_scan,
    seq_tup_read,
    idx_scan,
    ROUND(seq_scan::numeric / NULLIF(seq_scan + idx_scan, 0) * 100, 1) AS seq_scan_pct,
    pg_size_pretty(pg_total_relation_size(relid))   AS table_size
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_scan DESC;

-- ============================================================
-- SECTION 3: ADD MISSING INDEXES BASED ON QUERY PATTERNS
-- ============================================================

-- Index: declarations filtered by agency + status (covers query 1b)
CREATE INDEX IF NOT EXISTS idx_declarations_agency_status
    ON core.declarations(origin_agency, status);

-- Index: declarations filtered by risk level (used in monitoring)
CREATE INDEX IF NOT EXISTS idx_declarations_risk
    ON core.declarations(risk_level)
    WHERE risk_level IN ('HIGH', 'MEDIUM');

-- Index: JSONB country field (covers query 1c)
CREATE INDEX IF NOT EXISTS idx_declarations_country
    ON core.declarations((payload->>'country'));

-- Index: JSONB invoice amount for range queries
CREATE INDEX IF NOT EXISTS idx_declarations_invoice
    ON core.declarations(((payload->>'invoice_usd')::numeric));

-- Index: audit log by action type
CREATE INDEX IF NOT EXISTS idx_audit_action
    ON audit.event_log(action, event_time DESC);

-- Index: sync log by agency + status for dashboard queries
CREATE INDEX IF NOT EXISTS idx_sync_agency_status
    ON core.sync_log(source_agency, sync_status, started_at DESC);

-- ============================================================
-- SECTION 4: RE-RUN EXPLAIN AFTER INDEXES (compare plans)
-- ============================================================

-- Should now show "Index Scan" instead of "Seq Scan"
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    a.agency_code,
    d.declaration_no,
    d.status,
    d.payload->>'cargo' AS cargo
FROM core.declarations d
JOIN core.agencies a ON a.agency_id = d.origin_agency
WHERE a.agency_code = 'CUSTOMS'
  AND d.status = 'PENDING';

-- JSONB country filter – should use idx_declarations_country
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT declaration_no, payload->>'cargo' AS cargo
FROM core.declarations
WHERE payload->>'country' = 'CN';

-- ============================================================
-- SECTION 5: TABLE & INDEX SIZE REPORT
-- ============================================================
SELECT
    t.schemaname,
    t.relname                                           AS table_name,
    pg_size_pretty(pg_table_size(t.relid))              AS table_size,
    pg_size_pretty(pg_indexes_size(t.relid))            AS indexes_size,
    pg_size_pretty(pg_total_relation_size(t.relid))     AS total_size,
    t.n_live_tup                                        AS live_rows
FROM pg_stat_user_tables t
ORDER BY pg_total_relation_size(t.relid) DESC;

-- ============================================================
-- SECTION 6: UNUSED INDEXES (candidates for removal)
-- ============================================================
SELECT
    schemaname,
    relname         AS table_name,
    indexrelname    AS index_name,
    idx_scan        AS times_used,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelname NOT LIKE '%pkey%'   -- keep primary keys
ORDER BY pg_relation_size(indexrelid) DESC;

-- ============================================================
-- SECTION 7: VACUUM & ANALYZE (refresh planner statistics)
-- ============================================================
ANALYZE core.declarations;
ANALYZE core.sync_log;
ANALYZE audit.event_log;

-- Check when tables were last vacuumed/analyzed
SELECT
    relname,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    n_dead_tup     AS dead_tuples
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- ============================================================
-- SECTION 8: QUERY PERFORMANCE SUMMARY
-- ============================================================
SELECT
    LEFT(query, 100)                                    AS query_snippet,
    calls,
    ROUND((total_exec_time / calls)::numeric, 2)        AS avg_ms,
    ROUND(total_exec_time::numeric, 2)                  AS total_ms,
    rows
FROM pg_stat_statements
WHERE calls > 1
ORDER BY avg_ms DESC
LIMIT 15;
