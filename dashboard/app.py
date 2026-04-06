"""
NSW Platform – Live Dashboard Backend
Run: python3 dashboard/app.py
"""

import os
import psycopg2
import psycopg2.extras
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv

load_dotenv("api-integration/.env")

app = FastAPI(title="NSW Platform Dashboard")

# Works both in Docker (NSW_DB_DSN env var) and locally (from .env)
DB_DSN = os.getenv("NSW_DB_DSN", "postgresql://postgres:postgres_dev@localhost:5433/nsw_platform")

def query(sql: str, params=None):
    conn = psycopg2.connect(DB_DSN, cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()

# ── API endpoints ─────────────────────────────────────────────

@app.get("/api/stats")
def stats():
    rows = query("""
        SELECT
            COUNT(*)                                            AS total_declarations,
            COUNT(*) FILTER (WHERE status = 'PENDING')         AS pending,
            COUNT(*) FILTER (WHERE status = 'APPROVED')        AS approved,
            COUNT(*) FILTER (WHERE status = 'REJECTED')        AS rejected,
            COUNT(*) FILTER (WHERE risk_level = 'HIGH')        AS high_risk,
            COUNT(*) FILTER (WHERE risk_level = 'MEDIUM')      AS medium_risk,
            COUNT(*) FILTER (WHERE risk_level = 'LOW')         AS low_risk
        FROM core.declarations
    """)
    return rows[0]

@app.get("/api/by-agency")
def by_agency():
    return query("""
        SELECT a.agency_code, a.agency_name, COUNT(d.declaration_id) AS total,
               COUNT(d.declaration_id) FILTER (WHERE d.status = 'PENDING')  AS pending,
               COUNT(d.declaration_id) FILTER (WHERE d.status = 'APPROVED') AS approved,
               COUNT(d.declaration_id) FILTER (WHERE d.risk_level = 'HIGH') AS high_risk
        FROM core.agencies a
        LEFT JOIN core.declarations d ON d.origin_agency = a.agency_id
        WHERE a.agency_code IN ('CUSTOMS','PORTS','NAFDAC')
        GROUP BY a.agency_code, a.agency_name
        ORDER BY total DESC
    """)

@app.get("/api/sync-status")
def sync_status():
    return query("""
        SELECT a.agency_code, s.sync_status, s.records_synced,
               s.started_at, s.completed_at, s.error_detail,
               EXTRACT(EPOCH FROM (s.completed_at - s.started_at))::int AS duration_secs
        FROM core.sync_log s
        JOIN core.agencies a ON a.agency_id = s.source_agency
        ORDER BY s.started_at DESC
        LIMIT 15
    """)

@app.get("/api/audit-log")
def audit_log():
    return query("""
        SELECT event_time, action, resource_table, resource_id,
               new_values->>'status'          AS new_status,
               new_values->>'declaration_no'  AS declaration_no
        FROM audit.event_log
        ORDER BY event_time DESC
        LIMIT 20
    """)

@app.get("/api/recent-declarations")
def recent_declarations():
    return query("""
        SELECT d.declaration_no, d.declaration_type, d.status, d.risk_level,
               d.payload->>'cargo'       AS cargo,
               d.payload->>'country'     AS country,
               d.payload->>'invoice_usd' AS invoice_usd,
               a.agency_code,
               d.updated_at
        FROM core.declarations d
        JOIN core.agencies a ON a.agency_id = d.origin_agency
        ORDER BY d.updated_at DESC
        LIMIT 20
    """)

# ── Dashboard HTML ────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
def dashboard():
    with open("dashboard/templates/index.html") as f:
        return f.read()
