-- ============================================================
-- NSW Platform – Dev Schema (pg_partman-free for local setup)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Schemas
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS customs;
CREATE SCHEMA IF NOT EXISTS ports;
CREATE SCHEMA IF NOT EXISTS nafdac;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS governance;

-- Data classification enum
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

-- Agencies
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
    ('CUSTOMS', 'Nigeria Customs Service',          'Finance'),
    ('PORTS',   'Nigerian Ports Authority',          'Transport'),
    ('NAFDAC',  'NAFDAC',                            'Health'),
    ('SON',     'Standards Organisation of Nigeria', 'Industry'),
    ('NESREA',  'NESREA',                            'Environment');

-- Users
CREATE TABLE core.platform_users (
    user_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username        VARCHAR(100) UNIQUE NOT NULL,
    email           TEXT UNIQUE NOT NULL,
    password_hash   TEXT NOT NULL,
    agency_id       UUID REFERENCES core.agencies(agency_id),
    role            TEXT NOT NULL,
    mfa_enabled     BOOLEAN DEFAULT TRUE,
    last_login      TIMESTAMPTZ,
    failed_attempts SMALLINT DEFAULT 0,
    locked_until    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Declarations (no partitioning for local dev)
CREATE TABLE core.declarations (
    declaration_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    declaration_no   VARCHAR(50) UNIQUE NOT NULL,
    declarant_id     UUID REFERENCES core.platform_users(user_id),
    origin_agency    UUID REFERENCES core.agencies(agency_id),
    declaration_type VARCHAR(50) NOT NULL,
    status           TEXT DEFAULT 'PENDING',
    risk_level       TEXT DEFAULT 'LOW',
    payload          JSONB NOT NULL,
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);

-- Sync log
CREATE TABLE core.sync_log (
    sync_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_agency   UUID REFERENCES core.agencies(agency_id),
    target_agency   UUID REFERENCES core.agencies(agency_id),
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    sync_status     TEXT NOT NULL,
    records_synced  INT DEFAULT 0,
    error_detail    TEXT,
    started_at      TIMESTAMPTZ DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

-- Audit log
CREATE TABLE audit.event_log (
    event_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_time      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    actor_id        UUID,
    actor_ip        INET,
    actor_agency    UUID,
    action          TEXT NOT NULL,
    resource_schema TEXT,
    resource_table  TEXT,
    resource_id     TEXT,
    old_values      JSONB,
    new_values      JSONB,
    session_id      TEXT,
    request_id      TEXT
);

-- Audit trigger
CREATE OR REPLACE FUNCTION audit.log_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO audit.event_log (
        actor_id, action,
        resource_schema, resource_table, resource_id,
        old_values, new_values
    ) VALUES (
        NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID,
        TG_OP,
        TG_TABLE_SCHEMA, TG_TABLE_NAME,
        CASE TG_OP WHEN 'DELETE' THEN row_to_json(OLD)->>'declaration_id'
                   ELSE row_to_json(NEW)->>'declaration_id' END,
        CASE TG_OP WHEN 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
        CASE TG_OP WHEN 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER audit_declarations
    AFTER INSERT OR UPDATE OR DELETE ON core.declarations
    FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- Indexes
CREATE INDEX idx_declarations_status  ON core.declarations(status);
CREATE INDEX idx_declarations_created ON core.declarations(created_at DESC);
CREATE INDEX idx_declarations_payload ON core.declarations USING GIN (payload);
CREATE INDEX idx_sync_log_status      ON core.sync_log(sync_status, started_at DESC);
CREATE INDEX idx_audit_resource       ON audit.event_log(resource_table, resource_id);

-- Sample data
INSERT INTO core.platform_users (username, email, password_hash, agency_id, role)
SELECT 'customs_user1', 'user1@customs.gov.ng',
       crypt('dev_password', gen_salt('bf')),
       agency_id, 'DECLARANT'
FROM core.agencies WHERE agency_code = 'CUSTOMS';

INSERT INTO core.declarations (declaration_no, origin_agency, declaration_type, status, payload)
SELECT
    'DCL-2026-00' || gs,
    agency_id,
    (ARRAY['IMPORT','EXPORT','TRANSIT'])[((gs-1) % 3) + 1],
    (ARRAY['PENDING','APPROVED','REJECTED'])[((gs-1) % 3) + 1],
    jsonb_build_object(
        'cargo',        'Electronics',
        'weight_kg',    gs * 100,
        'country',      'CN',
        'invoice_usd',  gs * 5000
    )
FROM core.agencies, generate_series(1, 10) gs
WHERE agency_code = 'CUSTOMS';
