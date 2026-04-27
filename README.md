# postgres-maintenance

Weekly PostgreSQL maintenance scripts deployed to our DB hosts.

## Files

| File | Purpose |
|---|---|
| `vacuum.sh` | Weekly maintenance: targeted `VACUUM (FREEZE)` on tables nearing wraparound, then parallel `vacuumdb --analyze` per database. Single-instance lock, log rotation. |
| `install.sh` | Installs/updates `vacuum.sh` and the cron entry on a host. Idempotent. |
| `set-dhcp.sh` | (unrelated) DHCP interface helper. |

## Deploy on a new host

```bash
curl -fsSL https://raw.githubusercontent.com/silversixpence-crypto/postgres-maintenance/main/install.sh \
    | sudo bash
```

This installs `/usr/local/sbin/vacuum.sh` (mode `0750`, owner `root`) and
adds a root crontab entry: `0 22 * * 5 /usr/local/sbin/vacuum.sh`.

Re-run the same command at any time to update to the latest `main`.

### Pinning to a specific revision

```bash
REF=c5f59cd
curl -fsSL "https://raw.githubusercontent.com/silversixpence-crypto/postgres-maintenance/${REF}/install.sh" \
    | sudo REF="$REF" bash
```

### Overriding defaults

Environment variables understood by `install.sh`:

| Variable | Default | Notes |
|---|---|---|
| `REF` | `main` | Branch, tag, or commit SHA. |
| `INSTALL_PATH` | `/usr/local/sbin/vacuum.sh` | |
| `CRON_SCHEDULE` | `0 22 * * 5` | |
| `CRON_USER` | `root` | |

Environment variables understood by `vacuum.sh` (set in cron line or
`/etc/default/vacuum.sh` if you wrap it):

| Variable | Default | Notes |
|---|---|---|
| `JOBS` | `6` | Parallel tables per DB (`vacuumdb -j`). |
| `PARALLEL_INDEX` | `8` | Parallel index workers per table. |
| `MAINT_MEM` | `16GB` | `maintenance_work_mem` for the run. |
| `COST_LIMIT` | `10000` | `vacuum_cost_limit` for the run. |
| `COST_DELAY` | `0` | `vacuum_cost_delay` (ms). |
| `FREEZE_AGE_THRESHOLD` | `500000000` | xid age that triggers a targeted FREEZE. |
| `LOG_DIR` | `/var/log/postgres-vacuum` | |
| `LOG_RETENTION_DAYS` | `30` | |
| `SKIP_DBS` | (empty) | Comma-separated DB names to skip. |

Tune these down on smaller hosts (e.g. `JOBS=2 PARALLEL_INDEX=2 MAINT_MEM=2GB`).

## Run on demand

```bash
sudo /usr/local/sbin/vacuum.sh
tail -f /var/log/postgres-vacuum/vacuum_*.log
```

## Recommended cluster-wide settings

Reload-only (apply via `ALTER SYSTEM` + `SELECT pg_reload_conf();`):

```sql
ALTER SYSTEM SET autovacuum_max_workers           = 8;
ALTER SYSTEM SET autovacuum_naptime               = '15s';
ALTER SYSTEM SET autovacuum_vacuum_cost_delay     = '2ms';
ALTER SYSTEM SET autovacuum_vacuum_cost_limit     = 4000;
ALTER SYSTEM SET autovacuum_work_mem              = '2GB';
ALTER SYSTEM SET vacuum_cost_limit                = 10000;
ALTER SYSTEM SET maintenance_work_mem             = '16GB';
ALTER SYSTEM SET max_parallel_maintenance_workers = 8;
ALTER SYSTEM SET autovacuum_freeze_max_age        = 1000000000;
ALTER SYSTEM SET vacuum_freeze_table_age          = 800000000;
ALTER SYSTEM SET track_io_timing                  = on;
```

Restart-only (`postmaster` context — schedule a restart):

```sql
ALTER SYSTEM SET shared_buffers       = '<~25% of RAM>';
ALTER SYSTEM SET effective_cache_size = '<~70% of RAM>';
ALTER SYSTEM SET max_worker_processes = 32;
ALTER SYSTEM SET max_parallel_workers = 32;
```

Scale numeric values to host RAM/cores. The values above target a 64-core / 377 GB host.

## Per-table autovacuum overrides

For very large or write-heavy tables, lower the scale factors so autovacuum
fires before millions of dead tuples accumulate:

```sql
ALTER TABLE <schema>.<table> SET (
    autovacuum_vacuum_scale_factor        = 0.02,
    autovacuum_vacuum_insert_scale_factor = 0.02,
    autovacuum_analyze_scale_factor       = 0.05,
    autovacuum_vacuum_cost_limit          = 10000,
    parallel_workers                      = 8
);
```
