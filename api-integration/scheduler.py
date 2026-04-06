"""
NSW Platform – Pipeline Scheduler
Runs agency syncs automatically on a fixed interval.
Usage: python3 scheduler.py
"""

import os
import time
import logging
import threading
from datetime import datetime
from dotenv import load_dotenv

from data_pipeline import AgencyConfig, run_sync

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
logger = logging.getLogger("nsw.scheduler")

# ── Interval ──────────────────────────────────────────────────
SYNC_INTERVAL_SECONDS = int(os.getenv("SYNC_INTERVAL_SECONDS", 300))  # default 5 min

# ── Agency configs ────────────────────────────────────────────
AGENCIES = [
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

# ── Run all syncs in parallel threads ─────────────────────────
def run_all_syncs():
    logger.info("━━━ Sync cycle started ━━━")
    threads = []
    for cfg in AGENCIES:
        t = threading.Thread(
            target=run_sync,
            args=(cfg, f"declarations?agency={cfg.agency_code}"),
            name=cfg.agency_code,
            daemon=True,
        )
        threads.append(t)
        t.start()

    for t in threads:
        t.join()

    logger.info("━━━ Sync cycle complete ━━━\n")

# ── Main loop ─────────────────────────────────────────────────
if __name__ == "__main__":
    logger.info("NSW Pipeline Scheduler started.")
    logger.info("Sync interval: %d seconds (%d minutes)",
                SYNC_INTERVAL_SECONDS, SYNC_INTERVAL_SECONDS // 60)
    logger.info("Agencies: %s", [a.agency_code for a in AGENCIES])

    while True:
        try:
            run_all_syncs()
        except Exception as exc:
            logger.error("Sync cycle failed: %s", exc, exc_info=True)

        next_run = datetime.now().strftime("%H:%M:%S")
        logger.info("Next sync in %d seconds. Waiting...", SYNC_INTERVAL_SECONDS)
        time.sleep(SYNC_INTERVAL_SECONDS)
