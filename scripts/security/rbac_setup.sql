-- ============================================================
-- NSW Platform – Role-Based Access Control & Security Hardening
-- Principle of Least Privilege applied throughout
-- ============================================================

-- ── Revoke defaults ───────────────────────────────────────────
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL    ON DATABASE nsw_platform FROM PUBLIC;

-- ── Base Roles (no LOGIN) ─────────────────────────────────────
CREATE ROLE nsw_readonly;
CREATE ROLE nsw_writer;
CREATE ROLE nsw_dba;
CREATE ROLE nsw_auditor;
CREATE ROLE nsw_api;

-- Readonly: SELECT on all schemas
GRANT USAGE  ON SCHEMA core, customs, ports, nafdac, audit, governance TO nsw_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA core, customs, ports, nafdac TO nsw_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT ON TABLES TO nsw_readonly;

-- Writer: INSERT/UPDATE/DELETE on core, no DDL
GRANT nsw_readonly TO nsw_writer;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO nsw_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT INSERT, UPDATE, DELETE ON TABLES TO nsw_writer;

-- Auditor: can read audit schema only
GRANT USAGE  ON SCHEMA audit TO nsw_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO nsw_auditor;

-- API gateway role: core write + no direct audit access
GRANT nsw_writer TO nsw_api;
REVOKE ALL ON SCHEMA audit FROM nsw_api;

-- DBA: full access (never used for app connections)
GRANT nsw_writer TO nsw_dba;
GRANT ALL ON ALL TABLES IN SCHEMA core, customs, ports, nafdac, audit, governance TO nsw_dba;
GRANT ALL ON ALL SEQUENCES IN SCHEMA core TO nsw_dba;

-- ── Login Accounts ────────────────────────────────────────────
-- Application service account
CREATE ROLE app_user     LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 200;
GRANT nsw_api TO app_user;

-- API gateway account
CREATE ROLE api_gateway  LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 100;
GRANT nsw_api TO api_gateway;

-- Replication account
CREATE ROLE repl_user    LOGIN REPLICATION ENCRYPTED PASSWORD 'CHANGE_ME';

-- Backup account
CREATE ROLE backup_user  LOGIN ENCRYPTED PASSWORD 'CHANGE_ME';
GRANT pg_read_all_data TO backup_user;

-- Monitoring account (Prometheus / Grafana)
CREATE ROLE monitoring_user LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 5;
GRANT pg_monitor TO monitoring_user;

-- ETL/pipeline account
CREATE ROLE etl_user     LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 20;
GRANT nsw_writer TO etl_user;

-- Agency read-only accounts
CREATE ROLE customs_ro   LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 50;
CREATE ROLE ports_ro     LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 50;
CREATE ROLE nafdac_ro    LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 50;
CREATE ROLE son_ro       LOGIN ENCRYPTED PASSWORD 'CHANGE_ME' CONNECTION LIMIT 20;
GRANT nsw_readonly TO customs_ro, ports_ro, nafdac_ro, son_ro;

-- DBA team (login, requires client certificate via pg_hba.conf)
CREATE ROLE dba_team     LOGIN CONNECTION LIMIT 10;
GRANT nsw_dba TO dba_team;

-- ── Row-Level Security (multi-agency isolation) ───────────────
ALTER TABLE core.declarations ENABLE ROW LEVEL SECURITY;

-- Agencies only see their own declarations
CREATE POLICY agency_isolation ON core.declarations
    USING (
        origin_agency = (
            SELECT agency_id FROM core.agencies
            WHERE agency_code = current_setting('app.current_agency', TRUE)
        )
        OR pg_has_role(current_user, 'nsw_dba', 'member')
    );

-- Audit log: only auditors and DBAs can read
ALTER TABLE audit.event_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_access ON audit.event_log
    USING (
        pg_has_role(current_user, 'nsw_auditor', 'member')
        OR pg_has_role(current_user, 'nsw_dba',   'member')
    );

-- ── Column-Level Encryption Wrappers ─────────────────────────
-- Use pgcrypto to encrypt PII columns at rest
-- Example: encrypt taxpayer NIN before insert
CREATE OR REPLACE FUNCTION core.encrypt_pii(plaintext TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SECURITY DEFINER AS $$
    SELECT encode(
        pgp_sym_encrypt(plaintext, current_setting('app.encryption_key')),
        'base64'
    );
$$;

CREATE OR REPLACE FUNCTION core.decrypt_pii(ciphertext TEXT)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT pgp_sym_decrypt(
        decode(ciphertext, 'base64'),
        current_setting('app.encryption_key')
    );
$$;

-- Only DBA and auditor roles may call decrypt
REVOKE EXECUTE ON FUNCTION core.decrypt_pii(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION core.decrypt_pii(TEXT) TO nsw_dba, nsw_auditor;

-- ── Password Policy Reminder ──────────────────────────────────
-- Enforce via passwordcheck extension or external IdP (recommended)
-- ALTER SYSTEM SET password_encryption = 'scram-sha-256';
-- Use Vault / AWS Secrets Manager to rotate passwords automatically.
