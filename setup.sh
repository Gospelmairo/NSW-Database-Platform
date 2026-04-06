#!/usr/bin/env bash
# ============================================================
# NSW Platform – One-command local dev setup
# Usage: bash setup.sh
# ============================================================
set -euo pipefail

log() { echo ""; echo "▶ $*"; }

log "Starting NSW Database Platform (local dev)..."

# 1. Start containers
log "Starting Docker containers..."
docker compose up -d --wait

# 2. Wait for DB to be ready
log "Waiting for database to be healthy..."
until docker exec nsw_primary_db pg_isready -U postgres -d nsw_platform -p 5432 -q; do
    sleep 2
done

log "Database is ready."

# 3. Show connection info
echo ""
echo "════════════════════════════════════════════"
echo "  NSW Platform is running!"
echo ""
echo "  PostgreSQL:"
echo "    Host:     localhost:5433"
echo "    Database: nsw_platform"
echo "    User:     postgres"
echo "    Password: postgres_dev"
echo ""
echo "  pgAdmin (web UI):"
echo "    URL:      http://localhost:5050"
echo "    Email:    admin@nsw.local"
echo "    Password: admin"
echo ""
echo "  Connect via psql:"
echo "    psql -h localhost -p 5433 -U postgres -d nsw_platform"
echo ""
echo "  Run health checks:"
echo "    psql -h localhost -p 5433 -U postgres -d nsw_platform \\"
echo "         -f scripts/monitoring/health_check.sql"
echo "════════════════════════════════════════════"
