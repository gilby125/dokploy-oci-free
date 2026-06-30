# Shared data services (fleet Postgres + Redis)

_Status: live as of 2026-06-30._

The OCI fleet runs **one** Postgres server and **one** Redis server, shared by
every app. Apps **must not** bundle their own `postgres`/`redis` container — they
connect to the shared services by URL. This keeps the free-tier footprint small
(one data process each, one backup pipeline) instead of a DB+cache per stack.

## Where they live

Both run on **`oci-w3`** (the DB-tier node), reachable only over the VCN-private
address **`10.0.0.244`**:

| Service  | Address              | Deploy location (on the node)        | Managed by |
|----------|----------------------|--------------------------------------|------------|
| Postgres | `10.0.0.244:5432`    | `/opt/agentplane-db/` (compose)      | hand-deployed |
| Redis    | `10.0.0.244:6379`    | `/opt/shared-redis/` (compose)       | hand-deployed |

Neither is Terraform- or Komodo-managed; they are hand-deployed docker-compose
stacks on the node. The Redis deploy files are mirrored (sanitized) in this repo
under `shared-services/redis/` for reproducibility. Postgres predates this doc
and is the same `agentplane-postgres:17` image + pgBackRest→R2 backup pipeline
described in `postgres-migration-runbook.md`.

## Network boundary

Nothing here is public. The bind is the VCN-private IP (Docker publishes only to
`10.0.0.244:<port>`, not `0.0.0.0`), and the OCI security list already allows all
intra-VCN traffic (`10.0.0.0/16`) while denying public access to 5432/6379. No
Terraform/security-list change is needed to onboard a new app — it just connects
from inside the VCN. Verified: `:6379`/`:5432` are unreachable from the public
internet; reachable from other fleet nodes over `10.0.0.244`.

## Security model

- **Per-app credentials, never shared.** Each app gets its own Postgres role +
  database and its own Redis ACL user. One app's compromise does not hand over
  another app's credentials.
- **Least privilege.**
  - Postgres: each role owns only its own database; `REVOKE ALL ... FROM PUBLIC`
    on each DB, `GRANT CONNECT, TEMP` to the owner role only. No superuser.
  - Redis: app users are `+@all -@dangerous` (no `FLUSHALL`/`FLUSHDB`/`KEYS`/
    `CONFIG`/etc.). The `default` user is `-@all +ping` — an unauthenticated
    connection can do nothing but PING. `protected-mode` is off **on purpose**:
    the security boundary is auth + VCN-private bind, not protected mode (which
    would only force loopback-or-nothing and break legitimate intra-VCN apps).
- **Secrets never committed.** Connection URLs / passwords are set as
  **Komodo Stack-level `environment` vars** on each app's stack, not in the
  app's git repo. The compose files reference `${VAR}` and (where safe) fail
  loudly if a required one is missing. The real Redis `users.acl` is gitignored;
  only `users.acl.example` (placeholder passwords) is committed.

## Current tenants

| App stack             | Server | Postgres            | Redis           |
|-----------------------|--------|---------------------|-----------------|
| `agentplane-prod`     | oci-main | `agentplane` db (role `agentplane`) | — |
| `agentplane-ads-node` | oci-w3 | `directory` db (role `ads_node`) | — |
| `baseballz-integrator`| oci-main | `baseball` db (role `baseball`, empty until the `reference` ingester is run) | user `baseballz`, db 0 |

## Onboarding a new app

1. **Postgres** (run as the `agentplane` superuser role on the shared server):
   ```sql
   CREATE ROLE myapp LOGIN PASSWORD '<strong-unique>';
   CREATE DATABASE myapp OWNER myapp;
   REVOKE ALL ON DATABASE myapp FROM PUBLIC;
   GRANT CONNECT, TEMP ON DATABASE myapp TO myapp;
   ```
2. **Redis** (only if the app needs a cache): add a line to
   `/opt/shared-redis/users.acl` on oci-w3 and reload —
   `user myapp on ><strong-unique> ~* &* +@all -@dangerous` — then
   `docker compose -f /opt/shared-redis/docker-compose.yml up -d --force-recreate`.
   Consider a key-prefix scope (`~myapp:*` instead of `~*`) if the app's keys are
   namespaced, for stronger cross-app isolation.
3. **Wire the app**: in the app's compose, reference the connection by env var
   (`DATABASE_URL`, `REDIS_URL`, or the framework's per-field vars) with a soft
   default so local/no-infra runs still parse. Set the real values as Komodo
   Stack-level `environment` on the app's stack. Do **not** add a `postgres` or
   `redis` service to the app's compose.

> Compose gotcha: docker compose interpolates the `environment:` of **every**
> service at parse time, even profile-disabled ones. Don't use `${VAR:?required}`
> on a service that's normally off (e.g. a profile-gated one-shot) — it will break
> deploys that legitimately leave that variable unset. Use a soft `${VAR:-}` there.
