-- ============================================================
-- NSW Platform – Database Health & Performance Monitoring
-- Run: psql -f health_check.sql | forward to Grafana / Prometheus
-- ============================================================

-- ── 1. Uptime & Availability ──────────────────────────────────
SELECT
    pg_postmaster_start_time()                       AS started_at,
    NOW() - pg_postmaster_start_time()               AS uptime,
    CASE WHEN pg_is_in_recovery() THEN 'REPLICA' ELSE 'PRIMARY' END AS role;

-- ── 2. Replication Lag (PRIMARY only) ────────────────────────
SELECT
    client_addr,
    application_name,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(sent_lsn, replay_lsn)
    )                                                AS replication_lag,
    sync_state
FROM pg_stat_replication
ORDER BY pg_wal_lsn_diff(sent_lsn, replay_lsn) DESC;

-- ── 3. Top 10 Slow Queries ────────────────────────────────────
SELECT
    LEFT(query, 120)                                 AS query_snippet,
    calls,
    ROUND((total_exec_time / calls)::NUMERIC, 2)     AS avg_ms,
    ROUND(total_exec_time::NUMERIC, 2)               AS total_ms,
    rows
FROM pg_stat_statements
WHERE calls > 10
ORDER BY avg_ms DESC
LIMIT 10;

-- ── 4. Table Bloat Estimate ───────────────────────────────────
SELECT
    schemaname,
    relname                                          AS table_name,
    pg_size_pretty(pg_total_relation_size(relid))    AS total_size,
    n_dead_tup                                       AS dead_tuples,
    n_live_tup                                       AS live_tuples,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS bloat_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;

-- ── 5. Index Usage ────────────────────────────────────────────
SELECT
    schemaname,
    relname                                          AS table_name,
    indexrelname                                     AS index_name,
    idx_scan                                         AS times_used,
    pg_size_pretty(pg_relation_size(indexrelid))     AS index_size,
    CASE WHEN idx_scan = 0 THEN 'UNUSED – review for removal' ELSE 'active' END AS status
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC
LIMIT 20;

-- ── 6. Long-Running Queries (>30s) ────────────────────────────
SELECT
    pid,
    usename,
    application_name,
    state,
    ROUND(EXTRACT(EPOCH FROM (NOW() - query_start))::NUMERIC, 1) AS running_seconds,
    LEFT(query, 120)                                 AS query_snippet,
    wait_event_type,
    wait_event
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < NOW() - INTERVAL '30 seconds'
ORDER BY running_seconds DESC;

-- ── 7. Lock Contention ────────────────────────────────────────
SELECT
    blocked.pid                                      AS blocked_pid,
    blocked.usename                                  AS blocked_user,
    blocking.pid                                     AS blocking_pid,
    blocking.usename                                 AS blocking_user,
    LEFT(blocked_activity.query, 80)                 AS blocked_query,
    LEFT(blocking_activity.query, 80)                AS blocking_query
FROM pg_locks blocked
JOIN pg_locks blocking
    ON  blocking.locktype  = blocked.locktype
    AND blocking.relation  = blocked.relation
    AND blocking.granted   = TRUE
    AND blocked.granted    = FALSE
JOIN pg_stat_activity blocked_activity  ON blocked_activity.pid  = blocked.pid
JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking.pid;

-- ── 8. Cache Hit Ratio (target > 99%) ────────────────────────
SELECT
    SUM(heap_blks_hit)  AS cache_hits,
    SUM(heap_blks_read) AS disk_reads,
    ROUND(
        100.0 * SUM(heap_blks_hit)
        / NULLIF(SUM(heap_blks_hit) + SUM(heap_blks_read), 0),
        2
    )                   AS cache_hit_pct
FROM pg_statio_user_tables;

-- ── 9. Transaction Rate ───────────────────────────────────────
SELECT
    datname,
    xact_commit   AS commits,
    xact_rollback AS rollbacks,
    ROUND(100.0 * xact_rollback / NULLIF(xact_commit + xact_rollback, 0), 2) AS rollback_pct,
    blks_hit,
    tup_inserted,
    tup_updated,
    tup_deleted
FROM pg_stat_database
WHERE datname = current_database();

-- ── 10. Partition Overview ────────────────────────────────────
SELECT
    parent.relname                                   AS parent_table,
    child.relname                                    AS partition_name,
    pg_size_pretty(pg_relation_size(child.oid))      AS partition_size,
    pg_get_expr(child.relpartbound, child.oid)       AS partition_range
FROM pg_inherits
JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
JOIN pg_class child  ON child.oid  = pg_inherits.inhrelid
WHERE parent.relname IN ('declarations', 'event_log')
ORDER BY parent.relname, child.relname;
