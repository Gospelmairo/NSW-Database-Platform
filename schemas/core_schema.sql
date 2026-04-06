-- ============================================================
-- NSW Platform Core Database Schema
-- Supports: Customs, Ports, NAFDAC, and interagency exchange
-- ============================================================

-- ── Extensions (PostgreSQL) ──────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_partman";   -- partition management
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- query perf

-- ── Schemas ──────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS core;       -- shared master data
CREATE SCHEMA IF NOT EXISTS customs;    -- Customs agency
CREATE SCHEMA IF NOT EXISTS ports;      -- Port authority
CREATE SCHEMA IF NOT EXISTS nafdac;     -- NAFDAC agency
CREATE SCHEMA IF NOT EXISTS audit;      -- audit trails
CREATE SCHEMA IF NOT EXISTS governance; -- data classification

-- ── Data Classification ───────────────────────────────────────
CREATE TYPE governance.classification_level AS ENUM (
    'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'SECRET', 'TOP_SECRET'
);

CREATE TABLE governance.data_classification (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_schema    TEXT NOT NULL,
    table_name      TEXT NOT NULL,
    column_name     TEXT NOT NULL,
    classification  governance.classification_level NOT NULL,
    pii             BOOLEAN DEFAULT FALSE,
    encryption_req  BOOLEAN DEFAULT FALSE,
    retention_days  INT,
    classified_by   TEXT NOT NULL,
    classified_at   TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (table_schema, table_name, column_name)
);

-- ── Agencies Master ───────────────────────────────────────────
CREATE TABLE core.agencies (
    agency_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agency_code     VARCHAR(20) UNIQUE NOT NULL,
    agency_name     TEXT NOT NULL,
    ministry        TEXT,
    api_endpoint    TEXT,
    is_active       BOOLEAN DEFAULT TRUE,
    sync_interval   INTERVAL DEFAULT '5 minutes',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO core.agencies (agency_code, agency_name, ministry) VALUES
    ('CUSTOMS', 'Nigeria Customs Service',         'Finance'),
    ('PORTS',   'Nigerian Ports Authority',         'Transport'),
    ('NAFDAC',  'NAFDAC',                           'Health'),
    ('SON',     'Standards Organisation of Nigeria','Industry'),
    ('NESREA',  'NESREA',                           'Environment');

-- ── Users & Roles ─────────────────────────────────────────────
CREATE TABLE core.platform_users (
    user_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username        VARCHAR(100) UNIQUE NOT NULL,
    email           TEXT UNIQUE NOT NULL,
    password_hash   TEXT NOT NULL,          -- bcrypt/argon2
    agency_id       UUID REFERENCES core.agencies(agency_id),
    role            TEXT NOT NULL,
    mfa_enabled     BOOLEAN DEFAULT TRUE,
    last_login      TIMESTAMPTZ,
    failed_attempts SMALLINT DEFAULT 0,
    locked_until    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Declarations (core cross-agency entity) ───────────────────
CREATE TABLE core.declarations (
    declaration_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    declaration_no   VARCHAR(50) UNIQUE NOT NULL,
    declarant_id     UUID REFERENCES core.platform_users(user_id),
    origin_agency    UUID REFERENCES core.agencies(agency_id),
    declaration_type VARCHAR(50) NOT NULL,   -- IMPORT / EXPORT / TRANSIT
    status           TEXT DEFAULT 'PENDING',
    risk_level       TEXT DEFAULT 'LOW',     -- LOW / MEDIUM / HIGH
    payload          JSONB NOT NULL,
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Monthly partitions (managed by pg_partman)
SELECT partman.create_parent(
    p_parent_table => 'core.declarations',
    p_control      => 'created_at',
    p_type         => 'native',
    p_interval     => 'monthly'
);

-- ── Interagency Sync Log ──────────────────────────────────────
CREATE TABLE core.sync_log (
    sync_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_agency   UUID REFERENCES core.agencies(agency_id),
    target_agency   UUID REFERENCES core.agencies(agency_id),
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    sync_status     TEXT NOT NULL,   -- SUCCESS / FAILED / PARTIAL
    records_synced  INT DEFAULT 0,
    error_detail    TEXT,
    started_at      TIMESTAMPTZ DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

-- ── Audit Trail ───────────────────────────────────────────────
CREATE TABLE audit.event_log (
    event_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_time      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    actor_id        UUID,
    actor_ip        INET,
    actor_agency    UUID,
    action          TEXT NOT NULL,    -- INSERT / UPDATE / DELETE / LOGIN / etc.
    resource_schema TEXT,
    resource_table  TEXT,
    resource_id     TEXT,
    old_values      JSONB,
    new_values      JSONB,
    session_id      TEXT,
    request_id      TEXT
) PARTITION BY RANGE (event_time);

SELECT partman.create_parent(
    p_parent_table => 'audit.event_log',
    p_control      => 'event_time',
    p_type         => 'native',
    p_interval     => 'monthly'
);

-- ── Generic Audit Trigger Function ───────────────────────────
CREATE OR REPLACE FUNCTION audit.log_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO audit.event_log (
        actor_id, action,
        resource_schema, resource_table, resource_id,
        old_values, new_values
    ) VALUES (
        current_setting('app.current_user_id', TRUE)::UUID,
        TG_OP,
        TG_TABLE_SCHEMA, TG_TABLE_NAME,
        CASE TG_OP WHEN 'DELETE' THEN row_to_json(OLD)->>'id'
                   ELSE row_to_json(NEW)->>'id' END,
        CASE TG_OP WHEN 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
        CASE TG_OP WHEN 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
    );
    RETURN NEW;
END;
$$;

-- Apply audit trigger to core tables
CREATE TRIGGER audit_declarations
    AFTER INSERT OR UPDATE OR DELETE ON core.declarations
    FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ── Indexes ───────────────────────────────────────────────────
CREATE INDEX idx_declarations_status    ON core.declarations(status);
CREATE INDEX idx_declarations_created   ON core.declarations(created_at DESC);
CREATE INDEX idx_declarations_payload   ON core.declarations USING GIN (payload);
CREATE INDEX idx_sync_log_status        ON core.sync_log(sync_status, started_at DESC);
CREATE INDEX idx_audit_actor            ON audit.event_log(actor_id, event_time DESC);
CREATE INDEX idx_audit_resource         ON audit.event_log(resource_table, resource_id);
