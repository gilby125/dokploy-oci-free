# Next-Work Handoff — agentplane on OCI via Komodo

_Last updated: 2026-06-03._

> **STATUS: production is LIVE and verified end-to-end.** The migration from
> Dokploy + Docker Swarm to Komodo Periphery + Caddy + agentplane is complete.
> `https://agentplane.doppelops.com` serves the public resolver through
> Cloudflare → OCI NLB → per-node Caddy → agentplane web, with **two healthy NLB
> backends** (`oci-main` full stack + `oci-w1` web replica). There is no
> outstanding deployment work — see "Verification (2026-06-03)" below. Next work
> is product/ops polish, tracked in the agentplane repo's own
> `docs/next-work-handoff.md`.

This captures what's done, what's live, and how it was verified so the next
session can pick up without re-deriving state.

For the deep reconstruction (auth quirks, exact IPs, API call shapes) see the
auto-memory `agentplane-oci-komodo-deployment`. This doc is the shorter,
action-oriented summary.

---

## Goal

Ship `agentplane` (repo at `/home/gilby/projects/agent_plane`) onto the OCI
free-tier infra defined by this Terraform repo. Dokploy is being removed; nodes
now run Komodo Periphery, managed by a **local** Komodo Core, fronted by an OCI
Network Load Balancer.

## Topology

```
Cloudflare (proxied, Full-Strict TLS)
  → OCI Flexible NLB (Always-Free, L4 passthrough, public IP 147.224.152.111)
    → per-node Caddy :443 (Cloudflare Origin cert)
      → agentplane serve --public :8080
```

- **Terraform owns the OCI infra** (instances, VCN, NLB, reserved IP, backups).
  Komodo does NOT manage the infra layer. Adapt existing TF; don't rewrite.
- **Local Komodo Core** at `root@192.168.1.200` (public `https://komodo.sdrcar.com`)
  is the top control plane. It manages the OCI nodes and will deploy Komodo Core
  + the agentplane stack onto OCI.
- **Postgres is EXTERNAL** (managed provider via `AGENTPLANE_DATABASE_URL`).
  Do not run a Postgres container on OCI — preserves free-tier disk.

---

## What's DONE ✅

- **Node bootstrap migrated** (`bin/komodo-periphery.sh`, commit 183b996): all 4
  nodes install `komodo-periphery:2` (:8120) via cloud-init, trusting the Core
  public key from instance metadata. Replaces the Dokploy/Swarm bootstrap.
- **Full destructive rebuild applied** (2026-06-03, OpenTofu 1.12.1): 4 A1.Flex
  nodes recreated as Periphery, AD-spread (main=AD-1, w1=AD-2, w2=AD-3, w3=AD-1).
- **NLB live**: public IP **147.224.152.111**; `agentplane.doppelops.com` → it,
  proxied.
- **All 4 nodes registered in Komodo Core**, status **Ok**, addressed by stable
  hostnames `https://oci-<n>.doppelops.com:8120` (oci-main/w1/w2/w3).
- **Stable per-node DNS** (commit 8fc8289, `cloudflare_record.oci_node`,
  DNS-only): keeps nodes addressable across instance recreation.
- **All 15 legacy `throughfire.net` records deleted** (`managed_dns_records = {}`).
- Bootstrap connectivity-check bug fixed (commit e57af54): no longer gates on a
  `ghcr.io` HEAD (which 4xx's); gates only on `get.docker.com`.
- OCI provider auth made configurable for session-token SSO (commit e140485).

## What's LIVE (verified 2026-06-03)

- Region `us-chicago-1`, tenancy `ocid1.tenancy.oc1..aaaa...62kq24q`.
- 4 nodes running Komodo Periphery (:8120).
- Reserved IP **170.9.237.30** on main (survives stop/start).
- Worker ephemeral IPs change on stop/start — rely on the `oci-*.doppelops.com`
  hostnames, not raw IPs.
- VCN `network-dokploy-efq71` 10.0.0.0/16; subnet `/24`.

---

## Remaining work — NONE (deployment complete) ✅

All three items below were verified complete on 2026-06-03 (see next section):

1. ~~Deploy the agentplane stack onto OCI~~ — **DONE.** `oci-main` runs the full
   stack (`compose.yaml` + `compose.prod.yaml`: web, admin, worker, init, caddy);
   `oci-w1` runs the web replica (`compose.prod-web.yaml`). Built on-node
   (`run_build=true`), no registry. Postgres is **Supabase** (pooler), object
   store is **Cloudflare R2** — NOT a Postgres/MinIO container on OCI. Admin is
   loopback-bound.
2. ~~Per-node Caddy terminating :443~~ — **DONE.** Caddy on each node terminates
   TLS with the Cloudflare Origin cert (`*.doppelops.com`, valid to 2041) and
   reverse-proxies to `web:8080`.
3. ~~Verify end-to-end~~ — **DONE.** See below.

### Verification (2026-06-03)

- Public, through Cloudflare — all HTTP 200:
  `GET /healthz` (`{"ok":true}`), `/metrics`, `/directory`,
  `/.well-known/agent-card.json`.
- NLB `agentplane-web` backend-set: **status OK, 2/2 backends healthy**, zero in
  critical/warning/unknown.
- NLB `147.224.152.111:443` presents the Cloudflare Origin CA cert, confirming
  the per-node Caddy is terminating TLS on the L4 passthrough path. (A plain
  `curl` direct to the NLB IP fails TLS verification — expected, since the Origin
  cert isn't publicly trusted; use `openssl s_client` or `curl -k` to probe it.)

The prod config and credentials live in the agentplane repo at
`agent_plane/deploy/komodo/` (`compose.prod.yaml`, `compose.prod-web.yaml`,
`Caddyfile`, gitignored `.env.prod`, `tls/`). Compose files are pushed to
`origin/main` and `origin/prod` so Komodo can clone+build them on the nodes.

### What's next (different repo)

Deployment is no longer the blocker. Product/ops work is tracked in
`agent_plane/docs/next-work-handoff.md`: a repeatable public smoke script,
runtime-observation proof, projection-rebuild recovery drill, provider-noise
cleanup (Supabase RLS, Komodo `init` exit shows "unhealthy" — both cosmetic),
and the publisher submission/API plan.

---

## Gotchas

- **Editing `bin/komodo-periphery.sh` changes `user_data` → forces instance
  replacement** on next apply. Registration survives (lives in Komodo's mongo,
  not on nodes); only addresses change, hence the stable hostnames.
- **OCI CLI needs `--auth security_token`** (or `export OCI_CLI_AUTH=security_token`).
  Session token ~1h; re-auth is interactive (browser SSO):
  `oci session authenticate --region us-chicago-1 --profile-name DEFAULT`.
- **`var.deploy` master switch**: `deploy = false` + apply tears down compute +
  NLB but preserves VCN, reserved IP, and backup bucket. Prevents
  "deploying over the top".
- **State location**: the share copy at
  `/mnt/smb/code/dokploy-oci-server/terraform.tfstate` holds canonical state;
  the local working copy now also has copied state. `/mnt/smb/...` is the SAME
  repo/commit — its "modified" files are CIFS mode noise, not real changes.
- No `terraform`/`tofu` binary was on the original machine for some edits — TF was
  not always `validate`'d before commit. Run `terraform fmt -check` +
  `terraform validate` before applying.

## Komodo Core API (from the Core box, 192.168.1.200)

```
# login → jwt
POST localhost:9120/auth/login
  {type:LoginLocalUser, params:{username:admin, password:<from /opt/komodo/compose.env>}}
  → .data.jwt

# create/register a server
POST /write {type:CreateServer, params:{name, config:{address, enabled:true}}}

# read state
POST /read {type:GetServerState | ListServers}
```

Core authenticates to peripheries by its public key (passkey-less):
`PERIPHERY_CORE_PUBLIC_KEY=MCowBQYDK2VuAyEAXUWswKDLsmGjWM3+ODWvsqOkEqnR81PIa0CN/OLKnx0=`
(public key — safe to record).

## Branch / repo state

- Working copy: `/home/gilby/projects/dokploy-oci-free`. `dev` and
  `feature/doppelops-agentplane` are at the same commit (8fc8289) — all
  agentplane work is on both.
- `docs/production-deployment-plan.md` (in the agentplane repo) is the
  provider-portable (Cloudflare/Supabase/R2) story — a complementary, different
  plan from this OCI+Komodo topology.
