# NSW Platform – Disaster Recovery Plan

## RTO / RPO Targets
| Tier | Component | RTO | RPO |
|------|-----------|-----|-----|
| 1 | Primary DB (Declarations, Sync) | 5 min | 0 (synchronous replication) |
| 2 | Agency Replica DBs | 15 min | < 1 min |
| 3 | Reporting / Analytics DB | 4 hours | 1 hour |

## Architecture Overview
```
                    ┌─────────────────────────┐
                    │   Load Balancer (HAProxy)│
                    └────────────┬────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                                     ▼
   ┌──────────────────┐                  ┌──────────────────┐
   │  PRIMARY DB       │ ──sync repl───► │  STANDBY DB       │
   │  (AZ-1 / DC-1)   │                  │  (AZ-2 / DC-2)   │
   └──────────────────┘                  └──────────────────┘
              │                                     │
              └──────── async repl ─────────────────►
                                          ┌──────────────────┐
                                          │  DR / Reporting  │
                                          │  (AZ-3 / Remote) │
                                          └──────────────────┘
```

## Failover Procedure (Automated – Patroni)
1. Patroni detects primary failure (TTL: 30s)
2. Leader election via etcd/Consul quorum
3. Best replica promoted to primary
4. HAProxy health check updates routing within 10s
5. Application reconnects via connection string (DNS failover)
6. Alert sent to on-call DBA via PagerDuty

## Manual Failover Steps (if automation fails)
```bash
# 1. Verify primary is down
pg_isready -h primary-db.nsw.gov.ng -p 5432

# 2. On standby: promote to primary
/usr/lib/postgresql/16/bin/pg_ctl promote -D /var/lib/postgresql/data

# 3. Update HAProxy backend
# Edit /etc/haproxy/haproxy.cfg → swap primary/standby IPs
systemctl reload haproxy

# 4. Notify application teams of new primary endpoint
# 5. Update DNS record: db.nsw.gov.ng → new primary IP
```

## WAL-PITR Recovery (point-in-time)
```bash
# Restore to a specific timestamp from S3 WAL archive
aws s3 sync s3://nsw-db-backups/wal/ /var/lib/postgresql/wal_archive/

# recovery.conf / postgresql.conf (PG 12+)
restore_command    = 'aws s3 cp s3://nsw-db-backups/wal/%f %p'
recovery_target_time = '2026-03-15 14:30:00 Africa/Lagos'
recovery_target_action = 'promote'
```

## Backup Restoration Test Schedule
| Test Type | Frequency | Owner |
|-----------|-----------|-------|
| Logical dump restore to test DB | Weekly (automated) | DBA team |
| Base backup restore + PITR | Monthly | DBA + DevOps |
| Full DR failover drill | Quarterly | DBA + Operations |

## Contact & Escalation
| Role | On-Call Channel |
|------|----------------|
| Primary DBA | PagerDuty policy: `nsw-db-p1` |
| Backup DBA | PagerDuty policy: `nsw-db-p2` |
| Infrastructure | Slack `#nsw-infra-alerts` |
| CISO (data breach) | Escalate within 1 hour per NDPR guidelines |
