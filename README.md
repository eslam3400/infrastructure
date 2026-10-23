# workspace

A self-hosted development workspace built on two mutually exclusive Docker
Compose stacks and a set of disposable **sandbox** containers for AI agents.

- **`compose.yaml`** — the **server** stack. Everything is fronted by Traefik
  (Let's Encrypt HTTPS), reached by hostname under a single domain. It also
  runs one shared **sandbox** (no Traefik route).
- **`compose.local.yaml`** — the **local** stack. No Traefik; every service
  binds a plain localhost/host port. The three slug **sandboxes** live here
  only.

Both stacks include the same infrastructure services (Portainer, DBgate,
PostgreSQL, MongoDB, Redis, RustFS) and the same sandbox image. Tooling inside
a sandbox is installed as needed — tools are not services of their own.

## Repository layout

```
.
├── Dockerfile               # the sandbox base image: Node.js 24 LTS (alpine) + basic tooling
├── compose.yaml             # server stack (Traefik + infra + one shared sandbox)
├── compose.local.yaml       # local stack (host ports + infra + three sandboxes)
├── flyakeed-vpn.sh          # Flyakeed FortiGate VPN connect script (openfortivpn + SAML)
└── docs/
    ├── INTEGRATION.md       # how a separate app joins the stack network
    └── AGENTS.md            # guidance for AI agents working on this repo
```

## Quickstart

### Local

```bash
cp .env.example .env      # fill in DOMAIN only if you need it; local stack ignores TLS
docker compose -f compose.local.yaml build    # shared sandbox image (layer-cached, one real build)
docker compose -f compose.local.yaml up -d    # infra + the three sandboxes
docker compose -f compose.local.yaml exec flyakeed bash   # enter and install what you need
```

### Server

```bash
cp .env.example .env && nano .env    # DOMAIN, ACME_EMAIL, credentials
docker compose build                 # shared sandbox image (layer-cached with local)
docker compose up -d
```

Install Docker and open the ports you need in your firewall (80/443, plus the
DB TCP ports for remote clients). The Traefik dashboard hash is set by hand —
see the [replication guide](#server-deployment--replication-guide) below.
Create the DNS A records (all under `${DOMAIN}`) before deploying so Let's
Encrypt can issue certificates.

## Sandboxes

Sandboxes are disposable playgrounds where an AI agent can do anything: if it
breaks something, recreate the container. They run as **unprivileged**
containers with no Docker-in-Docker, so they cannot touch host devices or the
Docker socket. The only host data they can see is the directory mounted as
their workspace.

The server stack (compose.yaml) also runs a single shared `sandbox`
(workspace `${HOST_WORKSPACES_PATH}` mounted at `/workspaces/sandbox`). It
has no Traefik route — enter it with `docker compose exec sandbox bash`.

| Sandbox  | Typical tools (install as needed)   |
|----------|-------------------------------------|
| flyakeed | gh, kiro-cli                        |
| vectora  | gh, opencode                        |
| personal | gh, opencode, kiro-cli              |

All sandboxes are idle toolboxes; enter one with
`docker compose -f compose.local.yaml exec <slug> bash`.
The base image already ships **Node.js 24 LTS**, git, curl, openssh-client,
nano, jq, ripgrep, less, unzip, xz, gnupg and procps — install anything else
inside the sandbox yourself. Handy one-liners:

| Tool         | Install inside the sandbox                                                             |
|--------------|-----------------------------------------------------------------------------------------|
| opencode     | `curl -fsSL https://opencode.ai/install \| bash`                                        |
| kiro-cli     | `curl -fsSL https://cli.kiro.dev/install \| bash`                                       |
| gh           | download the latest `gh_*_linux_*.tar.gz` from cli/cli releases, or `apk add gh`        |

Tools are not autostarted — start whatever you installed manually inside the
sandbox. After a container recreation the tools and their config are still
there (state lives in the volume); just start the process again.

Inside a sandbox you are **root** (uid 0), running with your host user's group
(gid 1000) and `umask 002`. So files created in the bind-mounted workspace —
including git commits — are `root:eslam` and group-writable: you can edit and
commit from the sandbox or the host as your normal user, interchangeably.

### Workspaces

Each sandbox bind-mounts a host directory set by the single
`HOST_WORKSPACES_PATH` env var: the server `sandbox` mounts
`${HOST_WORKSPACES_PATH}` at `/workspaces/sandbox`, and each local sandbox
mounts `${HOST_WORKSPACES_PATH}/<slug>` at `/workspace`. Point these at
directories that contain **nothing sensitive** — the AI can read and write
everything under the path.

### Persistent state

Each sandbox mounts a named volume at `/root` (its home). Credentials and tool
state written there — `gh` auth, opencode sessions, kiro-cli state, and
**npm global installs** (the image
sets npm's prefix to `/root/.local`, so `npm i -g` lands in the volume) —
**survives container destruction and recreation**. Nothing needs
re-authentication or re-configuration after a recreate.

To wipe a sandbox back to a clean slate (container + its state volume):

```bash
# sandboxes live in the local stack
docker compose -f compose.local.yaml rm -sf personal
docker volume rm workspace_personal_data
docker compose -f compose.local.yaml up -d personal
```

Everything installed under `/root` (and anything installed at image build
time) is gone after the volume removal — reinstall the tools you need.

The workspace bind mount and all infrastructure data are left untouched.

### Getting into a sandbox

```bash
# sandboxes live in the local stack:
docker compose -f compose.local.yaml exec flyakeed bash
```

## Flyakeed VPN

`flyakeed-vpn.sh` connects to the Flyakeed FortiGate VPN via
[openfortivpn](https://github.com/adrienverge/openfortivpn) with SAML login.
It installs openfortivpn first if it's missing (apk / apt / dnf / yum /
pacman / zypper / brew), starts openfortivpn in SAML mode, fetches the
Microsoft (Azure AD) login URL and opens it in your browser — you sign in
(password + MFA), and the tunnel comes up automatically.

The VPN stays up for as long as the script runs; press Ctrl-C to disconnect.

```bash
./flyakeed-vpn.sh
```

## Security model

- Sandboxes run **without** `privileged` and **without** Docker-in-Docker, so
  they cannot reach host devices or control the host Docker daemon.
- Each sandbox runs as **root inside the container** (uid 0), with your host
  group (gid 1000) and `umask 002`. That is container-local root: it does not
  grant host root, and the workspace directory and named state volume remain
  the only host data it touches.
- `HOST_WORKSPACES_PATH` is the only host data exposed; keep it free of secrets.
- Infrastructure secrets live in `.env` and are never mounted into sandboxes.

---

# Server deployment & replication guide

The server stack (`compose.yaml`) is fronted by **Traefik** (v3), which
terminates TLS via Let's Encrypt and routes every management/tooling service
(Portainer, DBgate) plus databases and object storage (PostgreSQL, MongoDB,
Redis, RustFS) by hostname under a single domain.

### Current stack

**Traefik is the only container that binds host ports.** Everything else is
reached through it by hostname — there are no per-service host-port mappings.
Set `DOMAIN` in `.env`; the hostnames below are all `<name>.${DOMAIN}`.

### Reverse proxy

| App | Image | Host ports | Data |
|-----|-------|-----------|------|
| Traefik | traefik:v3 | 80, 443, 5432, 27017, 6379 | `traefik_certs` |

### Server apps (HTTPS, port 443)

| App | Image | URL | Data |
|-----|-------|-----------|------|
| Portainer | portainer/portainer-ce | `https://portainer.${DOMAIN}` | `portainer_data` |
| DBgate | dbgate/dbgate | `https://dbgate.${DOMAIN}` | `dbgate_config` |
| Traefik dashboard | (built-in) | `https://traefik.${DOMAIN}` (basic auth) | — |
| sandbox | sandbox:latest (shared sandbox image) | — (no public route; `docker compose exec sandbox bash`) | `sandbox_data` |

### Databases & storage

| App | Image | Endpoint | Data |
|-----|-------|-----------|------|
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

### Local vs server (two compose files)

Each compose file pins its own project name — `infrastructure` (server) /
`workspace` (local) — so each stack owns its own network and volumes.
**Run only one at a time on a given host** (`docker compose down` before
switching).

| File | Environment | Entrypoint | Reachability |
|------|-------------|------------|--------------|
| `compose.yaml` | **Server / VPS** | Traefik (only host ports) | `https://<app>.${DOMAIN}` via public DNS + Let's Encrypt |
| `compose.local.yaml` | **Local box** | Direct localhost ports | `http://localhost:<port>` (no DNS/TLS) |

**Server (`compose.yaml`):** Traefik routes to every service by hostname,
and the databases are TLS-terminated through Traefik's TCP entrypoints
(80, 443, 5432, 27017, 6379). Requires DNS A records
(see [DNS](#dns-required)) before Let's Encrypt can issue certs.

**Local (`compose.local.yaml`):** no Traefik — every service binds a direct
localhost port, and the DBs are plain non-TLS endpoints — ideal for
`psql` / `mongosh` / `redis-cli` and app tooling. No DNS, no Let's Encrypt,
no public ports.

| App | Localhost URL |
|-----|---------------|
| Portainer | `http://localhost:9443` |
| DBgate | `http://localhost:3000` |
| RustFS console | `http://localhost:9001` |
| RustFS S3 | `http://localhost:9000` |
| PostgreSQL | `localhost:5432` (non-TLS) |
| MongoDB | `localhost:27017` (non-TLS) |
| Redis | `localhost:6379` (non-TLS) |

### DNS (required)

Because routing is hostname-based, create an **A record for each hostname**,
all pointing at the server's public IP:

```
traefik.${DOMAIN}    portainer.${DOMAIN}   dbgate.${DOMAIN}
storage.${DOMAIN}    s3.${DOMAIN}
postgres.${DOMAIN}   mongodb.${DOMAIN}     redis.${DOMAIN}
```

Let's Encrypt (TLS-ALPN-01) issues certs only after DNS resolves to this host
and ports 80/443 are reachable.

## Replication steps

### 1. Create the .env file

`.env` holds the domain/ACME settings, the dashboard credentials, and the
PostgreSQL/MongoDB/Redis/RustFS credentials.

```bash
cp .env.example .env
# Edit .env and fill in real values (DOMAIN, ACME_EMAIL, dashboard hash,
# passwords, keys)
nano .env
```

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
need it (one-liners in the Sandboxes section above).

Or via Portainer: **Stacks → Add stack**, name it `infrastructure`, paste the
contents of `compose.yaml`, and **Deploy the stack**.

## Connecting to the data services

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

## Data Migration (optional)

To carry over existing data from the old device:

Everything (configs and database data) lives in the Compose-managed named
volumes under each stack's project (`infrastructure_*` on the server,
`workspace_*` locally), so migrating means moving those volumes. Either back
them up with a temporary helper container:

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
