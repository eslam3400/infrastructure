# Server Config — Replication Guide

Two docker-compose stacks for one host: a server stack (`compose.yaml`)
fronted by **Traefik**, covering management/tooling (Portainer, DBgate) plus
databases and object storage (PostgreSQL, MongoDB, Redis, RustFS), and a local
stack (`compose.local.yaml`) exposing the same services directly on localhost
ports. Traefik terminates TLS (Let's Encrypt) and routes every service by
hostname under a single domain.

## Current Stack

**Traefik is the only container that binds host ports.** Everything else is
reached through it by hostname — there are no per-service host-port mappings.
Set `DOMAIN` in `.env`; the hostnames below are all `<name>.${DOMAIN}`.

### Reverse proxy

| App | Image | Host ports | Data |
|-----|-------|-----------|------|
| Traefik | traefik:v3 | 80, 443, 5432, 27017, 6379 | `traefik_certs` |

### Server apps (HTTPS, port 443)

| App | Image | URL | Data |
|-----|-------|-----|------|
| Portainer | portainer/portainer-ce | `https://portainer.${DOMAIN}` | `portainer_data` |
| DBgate | dbgate/dbgate | `https://dbgate.${DOMAIN}` | `dbgate_config` |
| Traefik dashboard | (built-in) | `https://traefik.${DOMAIN}` (basic auth) | — |
| sandbox | sandbox:latest (shared sandbox image) | — (no public route; `docker compose exec sandbox bash`) | `sandbox_data` |

### Databases & storage

| App | Image | Endpoint | Data |
|-----|-------|----------|------|
| PostgreSQL | postgres:18.6 | `postgres.${DOMAIN}:5432` (TCP+TLS) | `postgres_data` |
| MongoDB | mongo:8.0 | `mongodb.${DOMAIN}:27017` (TCP+TLS) | `mongodb_data` |
| Redis | redis:8.8.1 | `redis.${DOMAIN}:6379` (TCP+TLS) | `redis_data` |
| RustFS (S3 API) | rustfs/rustfs:latest | `https://s3.${DOMAIN}` | `rustfs_data` |
| RustFS (console) | rustfs/rustfs:latest | `https://storage.${DOMAIN}` | `rustfs_data` |

All services share the `infrastructure` bridge network, so `dbgate` reaches the
databases internally by container name (`postgres`, `mongodb`, `redis`) without
going through Traefik. The database services all have healthchecks. Credentials
and the domain are read from `.env`.

> **Note:** all data lives in Compose-managed **named volumes** (server project
> `infrastructure`, so e.g. `infrastructure_postgres_data`; local project
> `workspace`, so `workspace_postgres_data`). Docker creates and owns them
> automatically — there is no host directory prep. `traefik` is pinned
> to `:v3`; the data images are version-pinned; `rustfs`, `portainer`, and
> `dbgate` are unpinned (`:latest`).

### DNS (required)

Because routing is hostname-based, create an **A record for each hostname**, all
pointing at the server's public IP:

```
traefik.${DOMAIN}    portainer.${DOMAIN}   dbgate.${DOMAIN}
storage.${DOMAIN}    s3.${DOMAIN}
postgres.${DOMAIN}   mongodb.${DOMAIN}     redis.${DOMAIN}
```

Let's Encrypt (TLS-ALPN-01) issues certs only after DNS resolves to this host
and ports 80/443 are reachable.

---

## Live vs Local (two compose files)

There are **two mutually exclusive compose files**, one per environment. Each
pins its own project name — `infrastructure` (server) / `workspace` (local) —
so each stack owns its own network and volumes. **Run only one at a time on a
given host** (`docker compose down` before switching).

| File | Environment | Entrypoint | Reachability |
|------|-------------|------------|--------------|
| `compose.yaml` | **Server / VPS** | Traefik (only host ports) | `https://<app>.${DOMAIN}` via public DNS + Let's Encrypt |
| `compose.local.yaml` | **Local box** | Direct localhost ports | `http://localhost:<port>` (no DNS/TLS) |

### Server (`compose.yaml`)

**Traefik is the only container that binds host ports** (80, 443, 5432, 27017,
6379) and routes to every service by hostname. Reach apps at
`https://<app>.${DOMAIN}`. Databases are TLS-terminated through Traefik's TCP
entrypoints. The VPS is reached over public DNS. Requires DNS A
records (see [DNS](#dns-required)) before Let's Encrypt can issue certs.

```bash
docker compose up -d
```

### Local (`compose.local.yaml`)

**No Traefik.** Every service binds a direct localhost port, and the databases
are plain non-TLS endpoints — ideal for `psql` / `mongosh` / `redis-cli` and app
tooling. No DNS, no Let's Encrypt, no public ports.

```bash
docker compose -f compose.local.yaml up -d
```

| App | Localhost URL |
|-----|---------------|
| Portainer | `http://localhost:9443` |
| DBgate | `http://localhost:3000` |
| RustFS console | `http://localhost:9001` |
| RustFS S3 | `http://localhost:9000` |
| PostgreSQL | `localhost:5432` (non-TLS) |
| MongoDB | `localhost:27017` (non-TLS) |
| Redis | `localhost:6379` (non-TLS) |

---

## Replication Steps

### 1. Create the .env file

`.env` holds the domain/ACME settings, the dashboard credentials, and the
PostgreSQL/MongoDB/Redis/RustFS credentials.

```bash
cp .env.example .env
# Edit .env and fill in real values (DOMAIN, ACME_EMAIL, dashboard hash,
# passwords, keys)
nano .env
```

`.env` supplies the domain/ACME settings, the Traefik dashboard credentials, the
PostgreSQL, MongoDB, Redis, and RustFS credentials, and the sandbox workspace
root (`HOST_WORKSPACES_PATH`).

> **Gotcha:** any literal `$` in a value must be written as `$$` (compose turns
> `$$` back into `$`). This matters most for the bcrypt
> `TRAEFIK_DASHBOARD_USERS` hash. To generate it manually:
> ```bash
> docker run --rm httpd:alpine htpasswd -nbB admin 'yourpassword'
> ```
> then double every `$` before pasting into `.env`.
> **Never `source .env`** — compose reads it directly, and sourcing would let
> bash expand those `$`.

### 2. Point DNS at the host

Create the A records listed in [DNS (required)](#dns-required) above, all
resolving to the server's public IP, before deploying — Let's Encrypt needs them.

### 3. Prepare the host

Install Docker (if absent) and add your user to the `docker` group, then open
the ports you need in your firewall (22/80/443, plus the DB TCP ports if remote
clients connect). Persistent data is stored in Compose-managed named volumes,
which Docker creates automatically — no host directory prep needed.

`traefik` is **on-demand** — it is not auto-started. First time, start Traefik
via CLI so you can reach Portainer, then manage the rest from Portainer:

```bash
docker compose up -d traefik
# open https://portainer.${DOMAIN} and start the other services from Portainer
```

### 4. Deploy the full stack

```bash
docker compose build      # shared sandbox image (same Dockerfile as the local stack)
docker compose up -d
```

The server stack runs the infrastructure **plus one shared `sandbox`** (no
public route — reach it with `docker compose exec sandbox bash`). The three
slug sandboxes live in the local stack (compose.local.yaml):

```bash
docker compose -f compose.local.yaml build
docker compose -f compose.local.yaml up -d
```

Sandboxes come with Node.js LTS and the basics baked in (git, curl,
openssh-client, nano, ...) — install anything else inside the sandbox as you
need it (one-liners in the main README's Sandboxes section).

Or via Portainer: **Stacks → Add stack**, name it `infrastructure`, paste the
contents of `compose.yaml`, and **Deploy the stack**.

### Connecting to the data services

> **TLS is required.** Traefik terminates TLS in front of every database TCP
> entrypoint. A client that opens the socket without speaking TLS will hang
> until it times out — this looks like a network problem but is a missing SSL
> flag. Always enable TLS on the client side when connecting remotely.

The certs are Let's Encrypt-issued but Traefik presents them as a passthrough,
so most clients need `rejectUnauthorized: false` / `tlsAllowInvalidCertificates`
unless you explicitly supply the CA. This is fine for self-hosted dev databases.

**CLI**

```bash
psql 'host=postgres.${DOMAIN} port=5432 sslmode=require user=USER dbname=DB'
mongosh 'mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true'
redis-cli -h redis.${DOMAIN} -p 6379 -a PASS --tls --insecure
```

**NestJS / Node.js env vars** (set these when the API targets the remote host)

```bash
# .env  — remote dev server
POSTGRES_HOST=postgres.${DOMAIN}
POSTGRES_PORT=5432
DB_SSL=true          # enables ssl: { rejectUnauthorized: false } in db.config.ts

MONGO_URI=mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true
MONGO_SSL=true       # appends tls params to the URI in app-config.service.ts

REDIS_HOST=redis.${DOMAIN}
REDIS_PORT=6379
REDIS_TLS=true
```

```bash
# .env.prod  — containers on the same infrastructure network (no Traefik in the path)
DB_SSL=false
MONGO_SSL=false
REDIS_TLS=false
```

**Verification matrix**

| Connection | No TLS     | With TLS |
|------------|------------|----------|
| Postgres   | ❌ timeout | ✅ OK    |
| MongoDB    | ❌ timeout | ✅ OK    |

---

## Data Migration (optional)

To carry over existing data from the old device:

Everything (configs and database data) lives in the Compose-managed named
volumes under the project `infrastructure`, so migrating means moving those
volumes. Either back them up with a temporary helper container:

```bash
# On old device: stop the stack, then export each volume to a tarball
docker compose down
for v in traefik_certs portainer_data dbgate_config postgres_data \
         mongodb_data redis_data rustfs_data sandbox_data; do
  docker run --rm -v "infrastructure_${v}:/vol" -v "$PWD:/backup" alpine \
    tar czf "/backup/${v}.tgz" -C /vol .
done
# Local stack volumes live under the workspace_ prefix instead
# (workspace_postgres_data, workspace_flyakeed_data, ...) — same command with
# the matching prefix.
# copy the .tgz files to the new host and extract the same way (stack stopped)
```

Alternatively, do a logical dump per database (lets you migrate while running):

```bash
# On old device: dump and transfer
docker exec postgres pg_dumpall -U "$PG_USER" > postgres_dump.sql
docker exec mongodb mongodump --out /tmp/mongodump && \
  docker cp mongodb:/tmp/mongodump ./mongodump

# On new device: restore after starting the stack
cat postgres_dump.sql | docker exec -i postgres psql -U "$PG_USER"
docker cp ./mongodump mongodb:/tmp/mongodump && \
  docker exec mongodb mongorestore /tmp/mongodump
```

---

## File Layout

```
workspace/
├── .env.example          # Secrets + workspace-path template — copy to .env and fill in
├── README.md             # Repo overview + sandbox/security quickstart
├── Dockerfile            # The sandbox base image (Node.js 24 LTS + basic tooling)
├── compose.yaml          # SERVER stack (Traefik-fronted): portainer + dbgate + postgres + mongodb + redis + rustfs (no sandboxes)
├── compose.local.yaml    # LOCAL stack (host ports, no Traefik) — also where the sandboxes live
└── docs/
    ├── README.md         # This file
    ├── INTEGRATION.md    # How a separate app repo connects to the DBs + Traefik
    └── AGENTS.md         # Guidance for AI agents working on this repo
```
