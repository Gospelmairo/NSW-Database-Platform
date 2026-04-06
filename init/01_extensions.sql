-- Runs automatically on first Docker startup
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
-- pg_partman requires the background worker; skip for local dev
-- CREATE EXTENSION IF NOT EXISTS "pg_partman";
