# AGENTS.md

This file provides guidance to opencode when working with code in this repository.

## What this is

Two Docker Compose stacks for a self-hosted dev server (server + local), plus
disposable **sandbox** containers for AI agents, a shared sandbox `Dockerfile`,
and an env template. There is no application code — the "build" is building the
sandbox image and deploying containers. Everything lives in: `compose.yaml`,
`compose.local.yaml`, `Dockerfile`, `setup.sh`, `.env.example`.

## Common commands (run from the repo root)

```bash
# One-time on a fresh host: install Docker (add your user to the docker group),
# open the ports you need in your firewall, and fill in .env.
cp .env.example .env && nano .env        # DOMAIN, credentials, HERMES_USERNAME/PASSWORD

# Build the sandbox image (plain Docker build — no devcontainer CLI).
docker compose build
docker compose -f compose.local.yaml build

# Deploy / update the whole SERVER stack (Traefik-fronted)
# Do NOT `source .env` — docker compose reads it automatically. Sourcing it
# would let bash expand any $ in the values (e.g. the bcrypt dashboard hash).
docker compose up -d

# Deploy / update the LOCAL stack (direct localhost ports, no Traefik)
docker compose -f compose.local.yaml up -d

# traefik is on-demand (started from Portainer), not auto-started.
docker compose up -d traefik

# Install/reinstall selected tools into a sandbox (idempotent; see ./setup.sh)
./setup.sh flyakeed node gh kiro
./setup.sh vectora --local node claude cursor
./setup.sh personal node gh opencode hermes

# Wipe a sandbox's state volume and recreate it (flyakeed|vectora|personal)
docker compose rm -sf personal-sandbox            # add -f compose.local.yaml for local
docker volume rm infrastructure_personal-sandbox
docker compose up -d personal-sandbox
./setup.sh personal node gh opencode hermes       # reinstall tools afterwards

# Validate either compose file
docker compose config -q
docker compose -f compose.local.yaml config -q

# Tear down
docker compose down            # server stack
docker compose -f compose.local.yaml down   # local stack
```

There are **two mutually exclusive stacks**: `compose.yaml` (server) and
`compose.local.yaml` (local). They share the named volumes and the
`infrastructure` network name, so **never run both at once on the same host** —
stop one before starting the other. `compose.yaml` uses the default filename, so
`docker compose` finds it with no `-f` flag. Both pin the project name to
`infrastructure` via the top-level `name:` key.

## Architecture & invariants

Two stacks share one `infrastructure` bridge network name (never run both at once):

- **`compose.yaml` (server):** all services are **fronted by Traefik** — nothing
  is published on its own host port. Traefik is the only container that binds
  host ports (80, 443, and the TCP entrypoints 5432 / 27017 / 6379) and routes
  to everything else by Docker labels. No Tailscale.
- **`compose.local.yaml` (local):** **no Traefik** — every service publishes a
  direct host port, and the DBs are plain non-TLS endpoints.

Three logical groups (server stack):

- **Reverse proxy:** `traefik` (v3) — terminates TLS, gets certs from Let's
  Encrypt via the ACME **TLS-ALPN-01** challenge (`certresolver: le`), and
  routes by hostname. The dashboard is at `traefik.${DOMAIN}` behind basic auth.
- **Tooling:** `portainer`, `dbgate` — HTTP routers on
  `portainer.${DOMAIN}` / `dbgate.${DOMAIN}` (443). The Hermes Agent dashboard
  runs **inside the personal sandbox** (not a service of its own): the
  `personal-sandbox` service forwards the plain-text `HERMES_USERNAME` +
  `HERMES_PASSWORD` from `.env` as `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` +
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` (Hermes hashes the password in
  memory) and is routed at `hermes.personal.${DOMAIN}`. Hermes refuses a
  non-loopback bind unless an auth provider is configured — Traefik does *not*
  add a middleware on this router (that would double-prompt).
- **Data:** `postgres`, `mongodb`, `redis`, `rustfs` — each with a healthcheck.
  The databases use **TCP routers with `HostSNI` + TLS termination** on their
  own entrypoints; `rustfs` uses HTTP routers (`s3.${DOMAIN}`, `storage.${DOMAIN}`).

Server routing is hostname-based, so **every service needs a DNS A record**
(`traefik`, `portainer`, `dbgate`, `storage`, `s3`,
`postgres`, `mongodb`, `redis`, and the sandbox `hermes.personal` / `opencode.personal` — all under
`${DOMAIN}`, all pointing at the host's public IP).

## Sandboxes

All three sandboxes share the root `Dockerfile` (tag `sandbox-base:latest`);
there is no devcontainer and no Docker-in-Docker. Services are defined inline
in both compose files: `flyakeed-sandbox`, `vectora-sandbox`,
`personal-sandbox`. The image is intentionally bare — just `ubuntu` plus the
PATH/umask setup (see below); no user creation, no tools baked in. Each
sandbox installs what you ask for at runtime via `./setup.sh <slug> <tool>...`
(one shared script at the repo root: it validates the slug/tools on the host,
then pipes itself into the container where an `ensure_base` step installs the
base packages and only the requested tool handlers run — idempotent, tools:
`node` `gh` `kiro` `claude` `cursor` `opencode` `hermes` `all`, plus `base` to
bootstrap the base packages (git, curl, jq, ripgrep, procps, libatomic1, …)
alone — any other tool pulls them in too).

- **Identity / permissions.** Sandboxes run as **root (uid 0)** with the host
  user's group (`user: "0:1000"` in the compose files) and `umask 002` (wired
  into `/etc/bash.bashrc`, `/etc/profile.d/`, and `setup.sh`). Files written
  into the bind-mounted workspace (and git commits) are therefore `root:1000`
  and group-writable, so the host user edits/commits them normally. Keep the
  workspace host directory group-owned by 1000 with group write
  (`chgrp -R 1000`, `chmod -R g+rwX`).
- **Isolation is the point.** Sandboxes run **unprivileged** with no Docker
  socket and no host devices (container-local root does not change this). The
  only host data they see is the directory from `${<SLUG>_WORKSPACES_PATH}`
  (bind-mounted at `/workspaces/<slug>`). Never add a mount of a path that
  could contain secrets (e.g. `$HOME`, this repo's `.env`).
- **Persistent state:** each sandbox mounts the named volume
  `<slug>-sandbox` at `/root` (HOME). Everything the install handlers
  write there — nvm + node (`~/.nvm`), gh auth, opencode sessions
  (`~/.opencode`), hermes config/sessions (`~/.hermes`), kiro/claude/cursor
  state (`~/.local/bin`) — **survives container destruction and recreation**.
- **All three sandboxes are idle** (`command: sleep infinity`); enter them with
  `docker compose exec <slug>-sandbox bash`. The personal sandbox's Hermes
  gateway runs **inside** the sandbox: `./setup.sh personal hermes` installs it
  and starts `hermes gateway run` + the dashboard. There is no autostart — after
  a container recreation, re-run that command. Its dashboard is
  self-authenticated via the plain `HERMES_USERNAME` / `HERMES_PASSWORD` creds
  and routed at `hermes.personal.${DOMAIN}` (server) / `9229:9119` (local).
  The personal sandbox also exposes opencode's dashboard on port `4096`
  (`opencode web --hostname 0.0.0.0 --port 4096`) — routed at
  `opencode.personal.${DOMAIN}` (server) / `4096:4096` (local); no autostart.
- **Rebuild after changing the Dockerfile:** `docker compose build` then
  `docker compose up -d`. Tool state is preserved in the volume.
- **Full reset:** remove the container and its state volume
  (`infrastructure_<slug>-sandbox`), recreate it, then re-run
  `./setup.sh <slug> <tool>...` (see the Common commands block).

## Key invariants to preserve when editing infrastructure

- **All persistent infra data is in Compose-managed named volumes** declared in
  the top-level `volumes:` block of *both* compose files (project
  `infrastructure`, so the actual names are `infrastructure_<volume>`). Any new
  service needing persistence must declare a volume and (if used by both stacks)
  add it to the other compose file's `volumes:` block too.
- **Secrets come from `.env`** via `${VAR}` interpolation. Adding a credentialed
  service means adding the var to the relevant compose file(s) and `.env.example`.
- **Never `source .env`.** compose reads it directly; sourcing it into the shell
  lets bash expand `$` in values. A literal `$` in a value (notably the bcrypt
  `TRAEFIK_DASHBOARD_USERS` hash) must be written as `$$` in `.env` so compose
  emits a single `$`.
- **Exposing a new service publicly** means adding Traefik labels (router rule +
  entrypoint + `tls.certresolver: le` + a `loadbalancer.server.port`), a DNS
  record, and — for a new TCP entrypoint — a `ports:` line on traefik plus a
  firewall rule on the host.

Files that must stay in sync when services change: `compose.yaml` (the service +
its Traefik labels), `compose.local.yaml` (the same service's host ports), and
`.env.example` (its secrets). The README's service tables document the current
hostname/port/data layout.

## Notes

- `rustfs`, `portainer`, and `dbgate` are unpinned (`:latest`); `traefik` is
  pinned to `:v3` and the data images are version-pinned.
- The cSpell diagnostics flagging `dbgate`, `rustfs`, `healthcheck`, `traefik`,
  `certresolver`, etc. are spell-check noise, not errors.
