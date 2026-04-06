# NSW Platform – Data Governance & Compliance Policy

## 1. Data Classification Framework

| Level | Description | Examples | Encryption | Retention |
|-------|-------------|----------|------------|-----------|
| PUBLIC | Non-sensitive, publicly available | Agency names, port codes | No | Indefinite |
| INTERNAL | Internal operations | Declaration statuses, sync logs | In transit | 5 years |
| CONFIDENTIAL | Business-sensitive | Cargo manifests, trader profiles | At rest + in transit | 7 years |
| SECRET | Regulatory / PII | NIN, TIN, biometric refs | At rest + in transit + field-level | 10 years |
| TOP_SECRET | National security flags | Watchlist matches, intelligence tags | At rest + in transit + field-level + HSM | 15 years |

## 2. Data Retention Schedule
- All financial declarations: **7 years** (FIRS compliance)
- Audit event logs: **10 years** (EFCC, NCS regulatory requirement)
- User access logs: **3 years**
- Sync logs: **2 years** (operational)
- Automated purge via pg_partman `DROP PARTITION` after retention period

## 3. Regulatory Compliance Checklist
- [ ] **NDPR (Nigeria Data Protection Regulation)** – PII handling, consent, breach notification within 72 hours
- [ ] **CBN Data Privacy Guidelines** – Financial data encryption and access controls
- [ ] **NCS Act** – Customs data integrity and audit trail requirements
- [ ] **NAFDAC Act** – Product and shipment traceability records
- [ ] **NITDA Framework** – Cloud hosting, data localisation (primary DB within Nigeria)
- [ ] **ISO/IEC 27001** – Information security management alignment

## 4. Access Control Policy
- All access governed by Role-Based Access Control (RBAC) — see `scripts/security/rbac_setup.sql`
- Row-Level Security (RLS) enforces agency data isolation
- No direct table access for application users — all access via defined roles
- DBA access requires MFA + VPN + client certificate
- Quarterly access review; unused accounts disabled after 90 days

## 5. Audit Trail Requirements
- All INSERT / UPDATE / DELETE operations logged to `audit.event_log`
- Audit records are immutable (no UPDATE/DELETE privileges on audit schema)
- Audit logs replicated to a separate write-once storage bucket (S3 Object Lock)
- Monthly audit report generated for CISO review

## 6. Data Breach Response
1. DBA detects anomaly → alerts CISO within **1 hour**
2. CISO assesses breach scope → classifies under NDPR
3. If personal data affected → notify NITDA within **72 hours**
4. Affected agencies notified
5. Root cause analysis completed within **5 business days**
6. Post-incident report filed and controls updated

## 7. Key Management
- Encryption keys stored in **HashiCorp Vault** (on-premise) or **AWS KMS**
- Keys rotated every **90 days** for CONFIDENTIAL, every **30 days** for SECRET+
- Database never has direct access to plaintext keys at rest; keys injected via app config at startup
- HSM used for TOP_SECRET key material

## 8. Success Metrics (SLA Targets)
| Metric | Target | Measurement |
|--------|--------|-------------|
| System uptime | ≥ 99.9% | Prometheus / Grafana |
| Query p99 latency | < 500ms | pg_stat_statements |
| Replication lag | < 30 seconds | pg_stat_replication |
| Data accuracy (cross-agency) | 100% | Reconciliation job |
| Zero data breach incidents | 0 per year | Audit / SIEM |
| Backup success rate | 100% | Backup job logs |
| RTO (Tier-1 failover) | ≤ 5 minutes | DR drill results |
