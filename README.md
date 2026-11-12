# workspace

Two mutually exclusive Docker Compose stacks for a self-hosted development
workspace. Both run the same data services (Portainer, DBgate, PostgreSQL,
MongoDB, Redis, RustFS) and one disposable **sandbox** for AI agents; only the
server stack includes Traefik.

| Stack  | Compose file         | Project          | Access                                |
|--------|----------------------|------------------|---------------------------------------|
| Server | `compose.yaml`       | `infrastructure` | Traefik + HTTPS at `<name>.${DOMAIN}` |
| Local  | `compose.local.yaml` | `workspace`      | localhost ports, no TLS/Traefik       |

Run only one stack at a time — they reuse container names and host ports. Every
image is pinned to an exact version; update the pins deliberately.

## Layout

```
.
├── Dockerfile           # sandbox image: Node.js 26 LTS (Alpine) + basic CLI tools
├── compose.yaml         # server stack (Traefik + infra + sandbox)
├── compose.local.yaml   # local stack (host ports + infra + sandbox)
└── .env.example         # copy to .env and fill in
```

## Quickstart

```bash
cp .env.example .env    # set HOST_WORKSPACES_PATH to an absolute path

# Local
docker compose -f compose.local.yaml build
docker compose -f compose.local.yaml up -d
docker compose -f compose.local.yaml exec sandbox bash

# Server — create the DNS records below first, and set DOMAIN/ACME_EMAIL/credentials
docker compose build
docker compose up -d
```

## Sandbox

Each stack has one `sandbox` service — the place agents work.

- **Workspace:** `${HOST_WORKSPACES_PATH}` is mounted at `/workspace`; the
  sandbox shell starts there.
- **State:** `sandbox_data` is mounted at `/root`. npm globals, CLI auth, and
  session state survive container recreation; other runtime installs do not.
- **User:** root (uid 0) inside the container; files it writes through the bind
  mount are owned by root on the host. It is not privileged and has no Docker
  socket or host devices, so the workspace and state volume are all it can touch.
- **Image:** `sandbox:26.13.0`, built from `node:26.13.0-alpine3.24` plus git,
  curl, openssh-client, nano, jq, ripgrep, less, unzip, xz, gnupg and procps.

Reset the local sandbox (container + state volume):

```bash
docker compose -f compose.local.yaml rm -sf sandbox
docker volume rm workspace_sandbox_data
docker compose -f compose.local.yaml up -d sandbox
```

## Services

| Service    | Image                           | Server                              | Local                  | Volume           |
|------------|---------------------------------|-------------------------------------|------------------------|------------------|
| Traefik    | `traefik:v3.7.17`               | `traefik.${DOMAIN}` (basic auth)    | —                      | `traefik_certs`  |
| Portainer  | `portainer/portainer-ce:2.45.3` | `portainer.${DOMAIN}`               | `localhost:9443`       | `portainer_data` |
| DBgate     | `dbgate/dbgate:7.3.4`           | `dbgate.${DOMAIN}`                  | `localhost:5433`       | `dbgate_config`  |
| PostgreSQL | `postgres:18.6`                 | `postgres.${DOMAIN}:5432` (TLS)     | `localhost:5432`       | `postgres_data`  |
| MongoDB    | `mongo:9.0.4`                   | `mongodb.${DOMAIN}:27017` (TLS)     | `localhost:27017`      | `mongodb_data`   |
| Redis      | `redis:8.8.4`                   | `redis.${DOMAIN}:6379` (TLS)        | `localhost:6379`       | `redis_data`     |
| RustFS     | `rustfs/rustfs:1.0.4`           | `s3.${DOMAIN}`, `storage.${DOMAIN}` | `localhost:9000/9001`  | `rustfs_data`    |
| OpenCode   | `sandbox` (npm `opencode-ai`)   | `opencode.${DOMAIN}` (basic auth)   | `localhost:4096`       | `sandbox_data`   |
| sandbox    | `sandbox:26.13.0`               | —                                   | —                      | `sandbox_data`   |

On the server, Traefik is the only service with host `ports:` — it publishes
80/443 plus the database TCP ports. Everything else is reached through it by
Docker labels. All services share the `infrastructure` bridge network, so
DBgate reaches the databases by container name.

## Server deployment

1. **Environment** — fill `.env`: `DOMAIN`, `ACME_EMAIL`, database credentials,
   and `TRAEFIK_DASHBOARD_USERS`. Generate the dashboard hash with
   `docker run --rm httpd:alpine htpasswd -nbB admin 'yourpassword'`, then
   double every `$` (`$$`) so Compose does not interpolate it. Never
   `source .env`.
2. **DNS** — create A records for all hostnames, pointing at the server IP:

   ```
   traefik.${DOMAIN}    portainer.${DOMAIN}   dbgate.${DOMAIN}
   storage.${DOMAIN}    s3.${DOMAIN}    opencode.${DOMAIN}
   postgres.${DOMAIN}   mongodb.${DOMAIN}     redis.${DOMAIN}
   ```

3. **Host** — install Docker and open 22/80/443 plus the database TCP ports
   (5432/27017/6379) in the firewall.
4. **Deploy** — `docker compose build && docker compose up -d`. Traefik obtains
   Let's Encrypt certificates once DNS and ports 80/443 are reachable. To manage
   the stack from Portainer, add a Git-backed stack pointing at this repo
   (**Stacks → Add stack**), not a pasted compose file — the sandbox needs a
   build context.

## Remote database access

Traefik terminates TLS in front of each database entrypoint; clients must allow
the Let's Encrypt certificate (or trust its CA). Inside the `infrastructure`
network the links are plaintext.

```bash
psql 'host=postgres.${DOMAIN} port=5432 sslmode=require user=USER dbname=DB'
mongosh 'mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true'
redis-cli -h redis.${DOMAIN} -p 6379 -a PASS --tls --insecure
```

# Integrating an app

An app is a separate Compose project on the same host. Do not edit this repo;
join its network and publish through Traefik.

## Network

```yaml
# in the app's compose.yaml
networks:
  infrastructure:
    external: true        # reuse the running network, do not redefine it
```

Attach every app service with `networks: [infrastructure]`. The databases are
reachable only on this network, by container name — Traefik also only routes
backends it finds there.

## Data access (plaintext, internal)

| Service    | Host and port         | Notes                              |
|------------|-----------------------|------------------------------------|
| PostgreSQL | `postgres:5432`       | `sslmode=disable`                  |
| MongoDB    | `mongodb:27017`       | no `tls=true`                      |
| Redis      | `redis:6379`          | password required                  |
| RustFS     | `rustfs:9000`         | S3 API, path-style addressing      |
| OpenCode   | `sandbox` (npm `opencode-ai`)   | `opencode.${DOMAIN}` (basic auth)   | `localhost:4096`       | `sandbox_data`   |

```bash
postgres://USER:PASSWORD@postgres:5432/DBNAME?sslmode=disable
mongodb://USER:PASSWORD@mongodb:27017/DBNAME?authSource=admin
redis://:PASSWORD@redis:6379/0
```

Credentials come from the stack's `.env`; put the same values in the app's own
`.env` via `${VAR}`. Prefer a dedicated, least-privilege database user. There is
no cross-project `depends_on`, so retry database connections on boot.

## Publish through Traefik

The app must not bind host ports. Required labels: `traefik.enable=true`, a
`Host(...)` router on `websecure` with `tls.certresolver=le`, and
`loadbalancer.server.port` set to the app's internal port.

```yaml
# myapp/compose.yaml
name: myapp

services:
  api:
    image: your/api:1.0.0
    restart: unless-stopped
    environment:
      DATABASE_URL: "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${APP_DB}?sslmode=disable"
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

Add an A record for `api.<DOMAIN>`, then deploy with `docker compose up -d`.
Router ids must be unique; existing routers are `dashboard`, `portainer`,
`dbgate`, `rustfs-console` and `rustfs-s3`.

- **Path routing (optional):** add a `PathPrefix(...)` rule and a
  `stripprefix` middleware.
- **Raw TCP (only if not HTTP):** add a new Traefik entrypoint in
  `compose.yaml` plus a firewall rule.

## Checklist

- [ ] App is on the external `infrastructure` network.
- [ ] Database URLs use container names, plaintext, with no `ports:`.
- [ ] Secrets come from the app's own `.env` (`$` written as `$$`).
- [ ] Traefik labels and the app's DNS record are in place.
- [ ] The app retries its database connection on boot.

# Maintenance

All state is in named volumes. Back up with a volume tarball or logical dumps
(`pg_dumpall`, `mongodump`) before changing pinned image versions. Volumes use
the project prefix: `infrastructure_*` on the server, `workspace_*` locally.
