# workspace

A self-hosted development workspace: two mutually exclusive Docker Compose
stacks and disposable **sandbox** containers for AI agents.

- **`compose.yaml`** — the **server** stack. Everything is fronted by Traefik
  (Let's Encrypt HTTPS), reached by hostname under a single domain. One
  shared **sandbox** runs here too (no Traefik route).
- **`compose.local.yaml`** — the **local** stack. No Traefik; every service
  binds a plain localhost port, and the three slug **sandboxes** live here
  only.

Both stacks include the same infrastructure services (Portainer, DBgate,
PostgreSQL, MongoDB, Redis, RustFS) and the same sandbox image. Tooling inside
a sandbox is installed as needed — tools are not services of their own.

## Repository layout

```
.
├── Dockerfile               # sandbox base image: Node.js 24 LTS (alpine) + basic tooling
├── compose.yaml             # server stack (Traefik + infra + one shared sandbox)
├── compose.local.yaml       # local stack (host ports + infra + three sandboxes)
└── flyakeed-vpn.sh          # Flyakeed FortiGate VPN connect script (openfortivpn + SAML)
```

## Quickstart

```bash
# Local — no DNS/TLS needed
cp .env.example .env
docker compose -f compose.local.yaml build    # shared sandbox image (one real build)
docker compose -f compose.local.yaml up -d    # infra + the three sandboxes
docker compose -f compose.local.yaml exec flyakeed bash

# Server — see the [deployment guide](#deployment-guide-server-stack) for
# DNS/host prep first
cp .env.example .env && nano .env             # DOMAIN, ACME_EMAIL, credentials
docker compose build && docker compose up -d
```

## Sandboxes

Sandboxes are disposable playgrounds for AI agents: if one breaks something,
recreate the container. They run **unprivileged** with no Docker-in-Docker —
no host devices, no Docker socket — so the only host data they see is the
workspace directory. The server stack also runs one shared `sandbox`
(`${HOST_WORKSPACES_PATH}` mounted at `/workspaces/sandbox`; enter it with
`docker compose exec sandbox bash`).

| Sandbox  | Typical tools (install as needed)   |
|----------|-------------------------------------|
| flyakeed | gh, kiro-cli                        |
| vectora  | gh, opencode                        |
| personal | gh, opencode, kiro-cli              |

Enter one with `docker compose -f compose.local.yaml exec <slug> bash`. The
base image (`sandbox:latest` from the root Dockerfile, `node:24-alpine`) ships
**Node.js 24 LTS**, git, curl, openssh-client, nano, jq, ripgrep, less, unzip,
xz, gnupg and procps — install anything else inside the sandbox yourself:

| Tool         | Install inside the sandbox                                                     |
|--------------|--------------------------------------------------------------------------------|
| opencode     | `curl -fsSL https://opencode.ai/install \| bash`                               |
| kiro-cli     | `curl -fsSL https://cli.kiro.dev/install \| bash`                              |
| gh           | `apk add gh`, or grab `gh_*_linux_*.tar.gz` from cli/cli releases              |

Tools are not autostarted — start what you install manually. Inside a sandbox
you are **root** (uid 0) with your host user's group (gid 1000) and
`umask 002`, so files created in the workspace are `root:eslam` and
group-writable — edit and commit from the sandbox or the host interchangeably.

### Workspaces

`HOST_WORKSPACES_PATH` is the single env var every workspace derives from: the
server `sandbox` mounts `${HOST_WORKSPACES_PATH}` at `/workspaces/sandbox`,
and each local sandbox mounts `${HOST_WORKSPACES_PATH}/<slug>` at
`/workspace`. Point it at a directory with **nothing sensitive** — the AI can
read and write everything under it.

### Persistent state

Each sandbox mounts a named volume at `/root` (its home): **npm global
installs** (the image sets npm's prefix to `/root/.local`, so `npm i -g` lands
in the volume), `gh` auth, opencode sessions and kiro-cli state all **survive
container destruction and recreation**. Anything installed via `apk` at
runtime lives in the container's ephemeral layer and does not — bake
recurring needs into the Dockerfile instead.

Wipe a sandbox back to a clean slate (container + its state volume):

```bash
docker compose -f compose.local.yaml rm -sf personal
docker volume rm workspace_personal_data
docker compose -f compose.local.yaml up -d personal
```

The workspace bind mount and all infrastructure data are left untouched.

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

- Sandboxes run **without** `privileged` and **without** Docker-in-Docker —
  no host devices, no Docker socket, no host root.
- Sandbox root (uid 0) is container-local; the workspace directory and the
  named state volume remain the only host data a sandbox touches.
- `HOST_WORKSPACES_PATH` is the only host data exposed; keep it free of
  secrets.
- Infrastructure secrets live in `.env` and are never mounted into sandboxes.

---

# Deployment guide (server stack)

The server stack is fronted by **Traefik** (v3), which terminates TLS via
Let's Encrypt and routes every service by hostname under a single domain.
**Traefik is the only container that binds host ports** — everything else is
reached through it by Docker labels, and the URLs below are all
`<name>.${DOMAIN}`.

### Services

| App                     | Image                     | Reachable at                                          | Data              |
|-------------------------|---------------------------|-------------------------------------------------------|-------------------|
| Traefik (reverse proxy) | traefik:v3                | host ports 80, 443, 5432, 27017, 6379                 | `traefik_certs`   |
| Portainer               | portainer/portainer-ce    | `https://portainer.${DOMAIN}`                         | `portainer_data`  |
| DBgate                  | dbgate/dbgate             | `https://dbgate.${DOMAIN}`                            | `dbgate_config`   |
| Traefik dashboard       | built-in                  | `https://traefik.${DOMAIN}` (basic auth)              | —                 |
| sandbox (shared)        | sandbox:latest            | no public route — `docker compose exec sandbox bash`  | `sandbox_data`    |
| PostgreSQL              | postgres:18.6             | `postgres.${DOMAIN}:5432` (TCP+TLS)                   | `postgres_data`   |
| MongoDB                 | mongo:8.0                 | `mongodb.${DOMAIN}:27017` (TCP+TLS)                   | `mongodb_data`    |
| Redis                   | redis:8.8.1               | `redis.${DOMAIN}:6379` (TCP+TLS)                      | `redis_data`      |
| RustFS (S3 API)         | rustfs/rustfs:latest      | `https://s3.${DOMAIN}`                                | `rustfs_data`     |
| RustFS (console)        | rustfs/rustfs:latest      | `https://storage.${DOMAIN}`                           | `rustfs_data`     |

All services share the `infrastructure` bridge network — `dbgate` reaches the
databases internally by container name without going through Traefik, and every
data service has a healthcheck. All data lives in Compose-managed **named
volumes** (server project `infrastructure` → `infrastructure_*`; local project
`workspace` → `workspace_*`) that Docker creates automatically. Pinning:
`traefik` on `:v3` and the data images version-pinned; `rustfs`, `portainer`
and `dbgate` unpinned (`:latest`).

### Local vs server

Each compose file pins its own project name (`infrastructure` server /
`workspace` local) and owns its own network and volumes; **run only one at a
time on a given host** (`docker compose down` before switching). The local
stack binds the same services to localhost ports instead — no Traefik,
non-TLS DBs, ideal for `psql` / `mongosh` / `redis-cli` and app tooling:

| App | Localhost URL |
|-----|--------|
| Portainer | `http://localhost:9443` |
| DBgate | `http://localhost:3000` |
| RustFS console | `http://localhost:9001` |
| RustFS S3 | `http://localhost:9000` |
| PostgreSQL | `localhost:5432` (non-TLS) |
| MongoDB | `localhost:27017` (non-TLS) |
| Redis | `localhost:6379` (non-TLS) |

### DNS

Routing is hostname-based, so create an **A record for each hostname**,
all pointing at the server's public IP:

```
traefik.${DOMAIN}    portainer.${DOMAIN}   dbgate.${DOMAIN}
storage.${DOMAIN}    s3.${DOMAIN}
postgres.${DOMAIN}   mongodb.${DOMAIN}     redis.${DOMAIN}
```

Let's Encrypt (TLS-ALPN-01) issues certs only after DNS resolves to this host
and ports 80/443 are reachable.

### Replication steps

1. **Create `.env`** — `cp .env.example .env` and fill in `DOMAIN`,
   `ACME_EMAIL`, credentials, and the bcrypt `TRAEFIK_DASHBOARD_USERS` hash
   (`docker run --rm httpd:alpine htpasswd -nbB admin 'yourpassword'`, then
   double every `$` in it — a literal `$` must be written as `$$` in `.env`).
   **Never `source .env`** — compose reads it directly, and sourcing would let
   bash expand those `$`.
2. **Point DNS** — create the A records above before deploying; Let's Encrypt
   needs them.
3. **Prepare the host** — install Docker (add your user to the `docker`
   group) and open 22/80/443 plus the DB TCP ports in the firewall. No host
   directory prep is needed.
4. **Deploy** — `docker compose build && docker compose up -d`. First boot,
   start Traefik via CLI (it is on-demand), then manage the rest from
   Portainer — or deploy straight from Portainer (**Stacks → Add stack**,
   name it `infrastructure`, paste `compose.yaml`):

   ```bash
   docker compose up -d traefik
   # open https://portainer.${DOMAIN}
   ```

### Remote database access (TLS)

Traefik terminates TLS in front of every database TCP entrypoint; a client
that opens the socket without TLS will hang until it times out. The certs are
Let's Encrypt-issued but presented as passthrough, so most clients need
`rejectUnauthorized: false` / `tlsAllowInvalidCertificates` unless you
explicitly supply the CA — fine for self-hosted dev databases.

```bash
psql 'host=postgres.${DOMAIN} port=5432 sslmode=require user=USER dbname=DB'
mongosh 'mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true'
redis-cli -h redis.${DOMAIN} -p 6379 -a PASS --tls --insecure
```

```bash
# NestJS / Node.js env vars — remote dev server
POSTGRES_HOST=postgres.${DOMAIN}
POSTGRES_PORT=5432
DB_SSL=true          # enables ssl: { rejectUnauthorized: false } in db.config.ts

MONGO_URI=mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true
MONGO_SSL=true       # appends tls params to the URI in app-config.service.ts

REDIS_HOST=redis.${DOMAIN}
REDIS_PORT=6379
REDIS_TLS=true

# from a container on the same infrastructure network (no Traefik in the path)
DB_SSL=false
MONGO_SSL=false
REDIS_TLS=false
```

### Data migration (optional)

Everything lives in the Compose-managed named volumes, so migrating means
moving them — either raw tarballs via a helper container:

```bash
# On old device: stop the stack, then export each volume (server imports as
# infrastructure_*; local stack volumes use the workspace_ prefix instead)
docker compose down
for v in traefik_certs portainer_data dbgate_config postgres_data \
         mongodb_data redis_data rustfs_data sandbox_data; do
  docker run --rm -v "infrastructure_${v}:/vol" -v "$PWD:/backup" alpine \
    tar czf "/backup/${v}.tgz" -C /vol .
done
# copy the .tgz files to the new host and extract the same way (stack stopped)
```

or a logical dump per database (lets you migrate while running):

```bash
docker exec postgres pg_dumpall -U "$PG_USER" > postgres_dump.sql
docker exec mongodb mongodump --out /tmp/mongodump && \
  docker cp mongodb:/tmp/mongodump ./mongodump

cat postgres_dump.sql | docker exec -i postgres psql -U "$PG_USER"
docker cp ./mongodump mongodb:/tmp/mongodump && \
  docker exec mongodb mongorestore /tmp/mongodump
```

---

# Integrating an app with the stack

For an app living in its own repo / its own compose project **beside the
server stack** (assumes the `infrastructure` stack is already deployed and
running on the same host — you add a *second* compose project, you don't edit
this one). The app needs to:

1. **Talk to the shared data services** (PostgreSQL, MongoDB, Redis, RustFS), and
2. **Be published to end users** through the shared Traefik proxy, without
   binding any host ports itself.

### Join the `infrastructure` network — the one rule

```yaml
# in YOUR app's compose.yaml
networks:
  infrastructure:
    external: true        # do NOT redefine it; reuse the running one
```

Then attach every service (`networks: [infrastructure]`). Everything below
depends on it: the databases are reachable **only inside this network, by
container name** (never on host ports), and Traefik only routes backends it
can find on it (`--providers.docker.network=infrastructure`) — an app on
another network is invisible to it even with perfect labels.

### Data access (internal, plaintext)

TLS termination only happens at Traefik for public traffic; inside the Docker
network it's a private link:

| Service    | Host (container name) | Port  | Notes |
|------------|-----------------------|-------|-------|
| PostgreSQL | `postgres`            | 5432  | `sslmode=disable` |
| MongoDB    | `mongodb`             | 27017 | no `tls=true` internally |
| Redis      | `redis`               | 6379  | password required (`--requirepass`) |
| RustFS     | `rustfs`              | 9000  | S3 API; path-style addressing |

```bash
postgres://USER:PASSWORD@postgres:5432/DBNAME?sslmode=disable
mongodb://USER:PASSWORD@mongodb:27017/DBNAME?authSource=admin
redis://:PASSWORD@redis:6379/0
# RustFS: endpoint http://rustfs:9000, forcePathStyle, RUSTFS_ACCESS_KEY/SECRET_KEY
```

Credentials come from the stack's `.env` (`PG_*`, `MONGO_*`, `REDIS_PASSWORD`,
`RUSTFS_*`); put the same values in **your app's own `.env`** via `${VAR}` —
never hard-code secrets. Best practice: create a dedicated, least-privilege DB
user for the app (via DBgate or `psql`/`mongosh`) instead of reusing the
superuser. Your project and the stack are separate projects — no
cross-project `depends_on`, so retry the DB connection on boot.

### Publishing through Traefik

Non-negotiables: `traefik.enable=true` (the stack runs with
`exposedbydefault=false`) and `loadbalancer.server.port` = the app's
**container-internal** port. Do **not** add a `ports:` mapping:

```yaml
services:
  myapp:
    image: your/image:tag
    restart: unless-stopped
    env_file: .env
    networks: [infrastructure]
    labels:
      traefik.enable: "true"
      traefik.http.routers.myapp.rule: "Host(`myapp.${DOMAIN}`)"
      traefik.http.routers.myapp.entrypoints: websecure
      traefik.http.routers.myapp.tls.certresolver: le
      traefik.http.services.myapp.loadbalancer.server.port: "3000"
```

On `docker compose up -d`, Traefik picks up the labels, requests a Let's
Encrypt cert for `myapp.<DOMAIN>` and serves on HTTPS (port 80 auto-redirects
to HTTPS, so no HTTP router is needed). Details:

- **Naming** — the `myapp` slug in the label keys is the router/service id;
  make it unique per app. Existing ids: `portainer`, `dbgate`,
  `rustfs-console`, `rustfs-s3`, `dashboard`.
- **DNS** — add an A record `myapp.<DOMAIN>` → the server's public IP
  (same `DOMAIN` as the stack), or Let's Encrypt can't issue the cert.
- **Path routing (optional)** —

  ```yaml
  traefik.http.routers.myapp.rule: "Host(`api.${DOMAIN}`) && PathPrefix(`/myapp`)"
  traefik.http.routers.myapp.middlewares: "myapp-strip"
  traefik.http.middlewares.myapp-strip.stripprefix.prefixes: "/myapp"
  ```

- **Raw TCP (only if not HTTP)** — needs a **new entrypoint** in the stack's
  `compose.yaml` (an `--entrypoints.<name>.address=:PORT` flag plus a `ports:`
  line on Traefik) and a firewall rule — coordinate with this repo.

### End-to-end example

A backend using Postgres + Redis, served at `https://api.<DOMAIN>`:

```yaml
# myapp/compose.yaml
name: myapp

services:
  api:
    image: your/api:latest
    restart: unless-stopped
    environment:
      DATABASE_URL: "postgres://${PG_USER}:${PG_PASSWORD}@postgres:5432/${APP_DB}?sslmode=disable"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@redis:6379/0"
    networks: [infrastructure]
    labels:
      traefik.enable: "true"
      traefik.http.routers.api.rule: "Host(`api.${DOMAIN}`)"
      traefik.http.routers.api.entrypoints: websecure
      traefik.http.routers.api.tls.certresolver: le
      traefik.http.services.api.loadbalancer.server.port: "8080"

networks:
  infrastructure:
    external: true
```

Deploy with `docker compose up -d` (`.env` holds `DOMAIN`, `PG_*`,
`REDIS_PASSWORD`, `APP_DB`, etc.).

**Integration checklist**

- [ ] `networks: [infrastructure]` and
      `networks.infrastructure.external: true` at the top level.
- [ ] DB connections target container names, **plaintext**, no `ports:`.
- [ ] Secrets come from the app's own `.env` via `${VAR}` (literal `$`
      written as `$$`).
- [ ] Traefik labels present: `traefik.enable=true`, a `Host(...)` router on
      `entrypoints: websecure` with `tls.certresolver: le`, and
      `loadbalancer.server.port` = the app's internal port.
- [ ] Router/service ids are unique; a DNS A record exists for the app's
      hostname; the app retries its DB connection on boot.
