"""
NSW Platform – Mock Agency API Server
Simulates the Customs, Ports, and NAFDAC agency endpoints.
Run: uvicorn mock_agency_api:app --port 8000 --reload
"""

import random
import uuid
from fastapi import FastAPI, Header, HTTPException, Query
from typing import Optional

app = FastAPI(title="NSW Mock Agency API", version="1.0")

# ── Auth check (simulates Bearer token validation) ────────────
VALID_KEYS = {"customs-dev-key", "ports-dev-key", "nafdac-dev-key"}

def check_auth(authorization: str = Header(...)):
    token = authorization.replace("Bearer ", "").strip()
    if token not in VALID_KEYS:
        raise HTTPException(status_code=401, detail="Invalid API key")

# ── Data generators ───────────────────────────────────────────
CARGO_TYPES  = ["Electronics", "Pharmaceuticals", "Food Products",
                "Machinery", "Textiles", "Chemicals", "Vehicles"]
COUNTRIES    = ["CN", "US", "DE", "IN", "GB", "FR", "JP", "AE", "ZA"]
STATUSES     = ["PENDING", "APPROVED", "UNDER_REVIEW", "REJECTED"]
RISK_LEVELS  = ["LOW", "LOW", "LOW", "MEDIUM", "MEDIUM", "HIGH"]

def make_declaration(agency: str, index: int) -> dict:
    prefix = {"CUSTOMS": "CUS", "PORTS": "PRT", "NAFDAC": "NAF"}.get(agency, "GEN")
    return {
        "declaration_no":   f"DCL-{prefix}-2026-{index:05d}",
        "declaration_type": random.choice(["IMPORT", "EXPORT", "TRANSIT"]),
        "status":           random.choice(STATUSES),
        "risk_level":       random.choice(RISK_LEVELS),
        "payload": {
            "cargo":        random.choice(CARGO_TYPES),
            "weight_kg":    random.randint(100, 50000),
            "country":      random.choice(COUNTRIES),
            "invoice_usd":  random.randint(5000, 500000),
            "vessel":       f"MV-{random.randint(1000,9999)}",
            "port_of_entry": random.choice(["Apapa", "Tin Can", "Onne", "Calabar"]),
            "hs_code":      f"{random.randint(10,99)}{random.randint(10,99)}{random.randint(10,99)}.{random.randint(10,99)}",
        }
    }

# ── Paginated declarations endpoint ───────────────────────────
@app.get("/declarations")
def get_declarations(
    agency:        str = Query("CUSTOMS"),
    page:          int = Query(1, ge=1),
    limit:         int = Query(20, ge=1, le=500),
    authorization: str = Header(...),
):
    check_auth(authorization)

    total_records = 47   # simulate 47 total records across pages
    start = (page - 1) * limit
    if start >= total_records:
        return {"data": [], "page": page, "total": total_records, "next": None}

    end   = min(start + limit, total_records)
    count = end - start

    records = [make_declaration(agency, start + i + 1) for i in range(count)]

    has_next = end < total_records
    return {
        "data":  records,
        "page":  page,
        "total": total_records,
        "next":  f"/declarations?agency={agency}&page={page+1}&limit={limit}" if has_next else None,
    }

# ── Single declaration lookup ─────────────────────────────────
@app.get("/declarations/{declaration_no}")
def get_declaration(
    declaration_no: str,
    authorization:  str = Header(...),
):
    check_auth(authorization)
    return make_declaration("CUSTOMS", 1) | {"declaration_no": declaration_no}

# ── Health endpoint ───────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "ok", "service": "NSW Mock Agency API"}
