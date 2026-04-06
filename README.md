# NSW Platform – Database Architecture

High-availability, secure database platform powering interagency data exchange
for Nigeria's National Single Window (NSW) system.

## System Architecture

```
Mock Agency APIs (port 8000)
        │
        ▼
Pipeline Scheduler  ──────────────── runs every 5 minutes
(api-integration/scheduler.py)       syncs all 3 agencies in parallel
        │
        ▼
Primary DB (port 5433) ──streaming replication──► Replica DB (port 5434)
├── 6 Schemas (core, audit, governance, customs, ports, nafdac)
├── Row-Level Security (agency data isolation)
├── Audit triggers (every write auto-logged)
├── Performance indexes (JSONB, status, agency, risk)
└── 50,000+ declarations with full query optimization
        │
        ▼
Dashboard (port 8081)  ──── live stats, charts, sync log, audit trail
pgAdmin   (port 5050)  ──── query tool & DB management
```

## Project Structure

```
NSW-Database-Platform/
├── schemas/
│   ├── core_schema.sql              # Core tables, audit triggers, indexes
│   └── replication_sync.sql         # Logical replication & sync procedures
├── config/
│   └── postgresql/
│       ├── postgresql.conf          # Production PostgreSQL tuning
│       └── pg_hba.conf              # Host-based auth (TLS required)
├── scripts/
│   ├── backup/backup.sh             # Automated base + logical backups → S3
│   ├── monitoring/
│   │   ├── health_check.sql         # Uptime, replication lag, slow queries
│   │   └── performance_tuning.sql   # EXPLAIN ANALYZE, index analysis
│   ├── security/rbac_setup.sql      # Roles, RLS, column-level encryption
│   └── migration/migrate.sh         # Version-controlled schema migrations
├── api-integration/
│   ├── data_pipeline.py             # Agency API → NSW DB sync pipeline
│   ├── mock_agency_api.py           # Mock agency API server (dev/test)
│   ├── scheduler.py                 # Automated sync scheduler (5 min interval)
│   ├── requirements.txt             # Python dependencies
│   └── .env                         # Local environment config
├── dashboard/
│   ├── app.py                       # FastAPI dashboard backend
│   └── templates/index.html         # Live web dashboard UI
├── governance/
│   └── data_governance_policy.md    # Classification, retention, compliance
├── disaster-recovery/
│   └── dr_plan.md                   # RTO/RPO, failover procedures, DR drills
├── init/
│   ├── 01_extensions.sql            # PostgreSQL extensions
│   └── 02_schema.sql                # Auto-loaded schema on first Docker start
└── docker-compose.yml               # Full stack: primary, replica, pgAdmin, dashboard
```

## Key Design Decisions

| Concern | Approach |
|---------|----------|
| High Availability | Primary + streaming replica (WAL-based, real-time) |
| Real-time sync | API pipeline scheduler — all agencies in parallel every 5 min |
| Data isolation | Row-Level Security per agency code |
| Audit trail | Immutable `audit.event_log` — auto-logged via triggers |
| Encryption | TLS in transit, pgcrypto at rest, KMS key management |
| Backups | WAL archiving (continuous) + nightly pg_dump → S3 |
| Performance | GIN indexes on JSONB, composite indexes, EXPLAIN ANALYZE verified |
| Compliance | NDPR, CBN, NCS, NAFDAC regulatory frameworks |

## Supported Agencies
- Nigeria Customs Service (NCS)
- Nigerian Ports Authority (NPA)
- NAFDAC
- Standards Organisation of Nigeria (SON)
- NESREA

## Running the Platform

### Start everything
```bash
docker compose up -d
```

### Start the mock API + scheduler
```bash
# Terminal 1 — mock agency API
python3 -m uvicorn api-integration.mock_agency_api:app --port 8000 --reload

# Terminal 2 — automated sync scheduler
python3 api-integration/scheduler.py
```

### Start the dashboard
```bash
python3 -m uvicorn dashboard.app:app --host 0.0.0.0 --port 8081 --reload
```

## Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| Live Dashboard | http://localhost:8081 | — |
| pgAdmin | http://localhost:5050 | admin@nsw.gov.ng / admin |
| Primary DB | localhost:5433 | postgres / postgres_dev |
| Replica DB | localhost:5434 | postgres / postgres_dev |
| Mock Agency API | http://localhost:8000/docs | — |

## Verify Replication
```sql
-- Run on primary in pgAdmin
SELECT client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
FROM pg_stat_replication;
-- Expected: 1 row, state = streaming
```

## SLA Targets
- Uptime: **99.9%+**
- Query p99 latency: **< 500ms**
- Replication lag: **< 30s**
- RTO (Tier-1): **5 minutes**
- Data breaches: **Zero**
