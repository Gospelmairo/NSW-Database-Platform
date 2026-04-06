"""
NSW Platform – API-Driven Data Pipeline
Handles real-time data exchange between agencies via REST APIs.
Pattern: Extract from agency API → Validate → Load into NSW DB
"""

import os
import logging
import psycopg2
import psycopg2.extras
import requests
from typing import Any
from dataclasses import dataclass
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
logger = logging.getLogger("nsw.pipeline")


# ── Config ────────────────────────────────────────────────────
@dataclass
class AgencyConfig:
    agency_code: str
    api_base_url: str
    api_key: str          # loaded from Vault / env, never hardcoded
    db_dsn: str
    timeout_secs: int = 30
    max_retries: int = 3
    batch_size: int = 500


# ── DB Connection (with connection pooling hint) ───────────────
def get_db_conn(dsn: str) -> psycopg2.extensions.connection:
    conn = psycopg2.connect(
        dsn,
        cursor_factory=psycopg2.extras.RealDictCursor,
        options="-c statement_timeout=60000",  # 60s query timeout
    )
    conn.autocommit = False
    return conn


# ── HTTP Client with retry & audit ───────────────────────────
class AgencyAPIClient:
    def __init__(self, cfg: AgencyConfig):
        self.cfg = cfg
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {cfg.api_key}",
            "Content-Type": "application/json",
            "X-NSW-Client": "nsw-pipeline/1.0",
        })
        # mTLS: load client cert for agency endpoints
        cert_path = os.getenv(f"{cfg.agency_code}_CERT_PATH")
        key_path  = os.getenv(f"{cfg.agency_code}_KEY_PATH")
        if cert_path and key_path:
            self.session.cert = (cert_path, key_path)
        self.session.verify = os.getenv("CA_BUNDLE", False)  # False = skip TLS verify in dev

    def fetch_page(self, endpoint: str, params: dict) -> dict[str, Any]:
        url = f"{self.cfg.api_base_url}/{endpoint.lstrip('/')}"
        for attempt in range(1, self.cfg.max_retries + 1):
            try:
                resp = self.session.get(url, params=params, timeout=self.cfg.timeout_secs)
                resp.raise_for_status()
                return resp.json()
            except requests.RequestException as exc:
                logger.warning("Attempt %d/%d failed for %s: %s",
                               attempt, self.cfg.max_retries, url, exc)
                if attempt == self.cfg.max_retries:
                    raise
        return {}


# ── Validation ────────────────────────────────────────────────
REQUIRED_FIELDS = {"declaration_no", "declaration_type", "payload"}

def validate_record(record: dict) -> tuple[bool, str]:
    missing = REQUIRED_FIELDS - record.keys()
    if missing:
        return False, f"Missing fields: {missing}"
    if record["declaration_type"] not in ("IMPORT", "EXPORT", "TRANSIT"):
        return False, f"Invalid declaration_type: {record['declaration_type']}"
    return True, ""


# ── Idempotent Upsert ──────────────────────────────────────────
UPSERT_SQL = """
    INSERT INTO core.declarations
        (declaration_no, declaration_type, status, payload, origin_agency, updated_at)
    SELECT
        %(declaration_no)s,
        %(declaration_type)s,
        %(status)s,
        %(payload)s::jsonb,
        a.agency_id,
        NOW()
    FROM core.agencies a
    WHERE a.agency_code = %(agency_code)s
    ON CONFLICT (declaration_no) DO UPDATE SET
        status      = EXCLUDED.status,
        payload     = EXCLUDED.payload,
        updated_at  = EXCLUDED.updated_at
    WHERE core.declarations.updated_at < EXCLUDED.updated_at;
"""


def load_batch(conn, records: list[dict], agency_code: str) -> int:
    """Upsert a batch of validated records. Returns count of rows affected."""
    rows = [
        {
            "declaration_no":   r["declaration_no"],
            "declaration_type": r["declaration_type"],
            "status":           r.get("status", "PENDING"),
            "payload":          psycopg2.extras.Json(r["payload"]),
            "agency_code":      agency_code,
        }
        for r in records
    ]
    with conn.cursor() as cur:
        psycopg2.extras.execute_batch(cur, UPSERT_SQL, rows, page_size=100)
    conn.commit()
    return len(rows)


# ── Sync Log ──────────────────────────────────────────────────
def log_sync(conn, agency_code: str, status: str, count: int, error: str = None):
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO core.sync_log
                (source_agency, target_agency, entity_type,
                 entity_id, sync_status, records_synced, error_detail, completed_at)
            SELECT
                a.agency_id, a.agency_id, 'declaration',
                uuid_generate_v4(), %s, %s, %s, NOW()
            FROM core.agencies a WHERE a.agency_code = %s
        """, (status, count, error, agency_code))
    conn.commit()


# ── Pipeline Entrypoint ───────────────────────────────────────
def run_sync(cfg: AgencyConfig, endpoint: str = "declarations"):
    logger.info("Starting sync: agency=%s", cfg.agency_code)
    client = AgencyAPIClient(cfg)
    conn   = get_db_conn(cfg.db_dsn)

    page, total_loaded, errors = 1, 0, []

    try:
        while True:
            data = client.fetch_page(endpoint, {"page": page, "limit": cfg.batch_size})
            records = data.get("data") or data.get("results") or []
            if not records:
                break

            valid_records = []
            for rec in records:
                ok, msg = validate_record(rec)
                if ok:
                    valid_records.append(rec)
                else:
                    errors.append({"record": rec.get("declaration_no"), "error": msg})
                    logger.warning("Validation failed: %s – %s", rec.get("declaration_no"), msg)

            if valid_records:
                loaded = load_batch(conn, valid_records, cfg.agency_code)
                total_loaded += loaded
                logger.info("Page %d: %d/%d records loaded.", page, loaded, len(records))

            if not data.get("next"):
                break
            page += 1

        log_sync(conn, cfg.agency_code, "SUCCESS", total_loaded)
        logger.info("Sync complete: %d records loaded, %d validation errors.",
                    total_loaded, len(errors))

    except Exception as exc:
        conn.rollback()
        log_sync(conn, cfg.agency_code, "FAILED", total_loaded, str(exc))
        logger.error("Sync failed: %s", exc, exc_info=True)
        raise
    finally:
        conn.close()


# ── Run all agency syncs ───────────────────────────────────────
if __name__ == "__main__":
    agencies = [
        AgencyConfig(
            agency_code  = "CUSTOMS",
            api_base_url = os.environ["CUSTOMS_API_URL"],
            api_key      = os.environ["CUSTOMS_API_KEY"],
            db_dsn       = os.environ["NSW_DB_DSN"],
        ),
        AgencyConfig(
            agency_code  = "PORTS",
            api_base_url = os.environ["PORTS_API_URL"],
            api_key      = os.environ["PORTS_API_KEY"],
            db_dsn       = os.environ["NSW_DB_DSN"],
        ),
        AgencyConfig(
            agency_code  = "NAFDAC",
            api_base_url = os.environ["NAFDAC_API_URL"],
            api_key      = os.environ["NAFDAC_API_KEY"],
            db_dsn       = os.environ["NSW_DB_DSN"],
        ),
    ]
    for cfg in agencies:
        run_sync(cfg, endpoint=f"declarations?agency={cfg.agency_code}")
