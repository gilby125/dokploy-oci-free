# shared-services/postgres

The self-hosted prod Postgres for Agent Plane (`postgres:17` + pgbackrest),
running on **worker-3** (oci-w3, 10.0.0.244:5432) — the "Postgres only" node.
Migrated off Supabase after the Free plan hit its 500 MB read-only wall (see
`../../docs/postgres-migration-runbook.md`).

## Deploy location

Lives on the host at `/opt/agentplane-db/`. This directory is the tracked source
of truth; the on-host copy must match it.

```sh
# on worker-3
cd /opt/agentplane-db
cp db.env.example db.env                 # fill in the real password
cp pgbackrest.conf.example pgbackrest.conf  # fill in the real R2 keys + cipher pass
docker compose up -d --build
```

`db.env` and `pgbackrest.conf` hold secrets (DB password; R2 access key/secret +
backup cipher pass) and are **gitignored** — only the `.example` templates are
tracked, exactly like `../redis/users.acl.example`.

## Tuning

The box is **1 OCPU / ~3 GB-capped** ARM on network SSD. Stock `postgres:17`
defaults (`work_mem=4MB`, parallel query on a single core, spinning-disk cost
model, a 4 GB cache estimate above the 3 GB cap) made the nightly crawl saturate
the DB and starve web startup (502s) and time out migrations. The `command:`
block sets the corrected values (also mirrored live in `postgresql.auto.conf` via
`ALTER SYSTEM`, applied without a restart). Key changes: `work_mem` 4→16 MB,
parallelism disabled for the single core, SSD cost model
(`random_page_cost=1.1`, `effective_io_concurrency=200`),
`effective_cache_size=2GB` matched to the cap, `shm_size` 64→256 MB, WAL sized up.

`shared_buffers`/`max_connections` are conservative for the 3 GB cap. The hard
ceiling is **1 OCPU** — if the crawl still strains the DB, the fix is more compute
(a dedicated/bigger DB instance) or a pgbouncer connection pooler, not more config.
