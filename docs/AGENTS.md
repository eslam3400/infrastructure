# AGENTS.md

This file provides guidance to opencode when working with code in this repository.

## What this is

Two Docker Compose stacks for a self-hosted dev server (server + local), plus
disposable **sandbox** containers for AI agents (one shared `sandbox` in the
server stack; three slug sandboxes in the local stack) and an env
template. There is no application code — the "build" is building the sandbox
image and deploying containers. Everything lives in: `compose.yaml`
(infrastructure + one `sandbox`), `compose.local.yaml` (infrastructure +
three sandboxes), `Dockerfile` (Node.js 24 LTS + base tooling),
`.env.example`. There is no
setup script: beyond the baked-in basics you install tools inside a sandbox
yourself.

## Common commands (run from the repo root)

```bash
# One-time on a fresh host: install Docker (add your user to the docker group),
# open the ports you need in your firewall, and fill in .env.
cp .env.example .env && nano .env        # DOMAIN, credentials, HERMES_USERNAME/PASSWORD

# Build the shared sandbox image (the server `sandbox` and the three local
# sandboxes all build the same Dockerfile — layer cache makes it a single
# real build).
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

# Enter a sandbox (flyakeed|vectora|personal) and install tools yourself;
# Node LTS, git, curl, openssh-client, nano, jq, ripgrep, ... are baked in.
docker compose -f compose.local.yaml exec personal-sandbox bash

# Wipe a sandbox's state volume and recreate it (flyakeed|vectora|personal)
docker compose -f compose.local.yaml rm -sf personal-sandbox
docker volume rm infrastructure_personal-sandbox
docker compose -f compose.local.yaml up -d personal-sandbox

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
  runs **inside the personal sandbox** (local stack, not a service of its own):
  the `personal-sandbox` service forwards the plain-text `HERMES_USERNAME` +
  `HERMES_PASSWORD` from `.env` as `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` +
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` (Hermes hashes the password in memory)
  and is reachable at `localhost:9229` in the local stack. Hermes refuses a
  non-loopback bind unless an auth provider is configured.
- **Data:** `postgres`, `mongodb`, `redis`, `rustfs` — each with a healthcheck.
  The databases use **TCP routers with `HostSNI` + TLS termination** on their
  own entrypoints; `rustfs` uses HTTP routers (`s3.${DOMAIN}`, `storage.${DOMAIN}`).
- **Sandbox:** `sandbox` — one idle toolbox (builds `sandbox-base:latest`
  from the root Dockerfile, same as the local sandboxes). No Traefik route and
  no published ports; enter it with `docker compose exec sandbox bash`.

Server routing is hostname-based, so **every service needs a DNS A record**
(`traefik`, `portainer`, `dbgate`, `storage`, `s3`,
`postgres`, `mongodb`, `redis` — all under `${DOMAIN}`, all pointing at the
host's public IP).

## Sandboxes

All three local sandboxes share the root `Dockerfile` (tag
`sandbox-base:latest`, based on the **latest Node.js LTS** — currently
`node:24-alpine`); there is no devcontainer and no Docker-in-Docker. The slug
services (`flyakeed-sandbox`, `vectora-sandbox`, `personal-sandbox`) are
defined in **compose.local.yaml**, and the server stack defines one shared
`sandbox` service in compose.yaml. The image bakes in
Node.js LTS plus base tooling at build time (git, curl, openssh-client, nano,
jq, ripgrep, less, unzip, xz, gnupg, procps). The Alpine base already includes
the CA certificate bundle and Node's runtime libraries. Beyond that you install
what you need **inside the sandbox**; handy one-liners for claude-code /
opencode / cursor-agent / kiro-cli / gh / hermes live in the main README's
Sandboxes section.

- **Identity / permissions.** Sandboxes run as **root (uid 0)** with the host
  user's group (`user: "0:1000"` in the compose files) and `umask 002` (wired
  into `/etc/bash.bashrc` and `/etc/profile.d/`). Files written
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
  `<slug>-sandbox` at `/root` (HOME). Credentials and tool state written
  there — gh auth, opencode sessions (`~/.opencode`), hermes config/sessions
  (`~/.hermes`), kiro/claude/cursor state, and npm global installs (the image
  sets npm's prefix to `/root/.local`, so `npm i -g` lands in the volume) —
  **survives container destruction and recreation**. Nothing needs
  re-auth or reinstall after a recreate. Note: anything installed via
  `apt` at *runtime* (not baked into the Dockerfile) lives in the container's
  ephemeral layer and does NOT survive — bake recurring needs into the
  Dockerfile instead.
- **All three sandboxes are idle** (`command: sleep infinity`); enter them with
  `docker compose -f compose.local.yaml exec <slug>-sandbox bash`. The personal
  sandbox's Hermes gateway runs **inside** the sandbox: install hermes inside
  it, then start `hermes gateway run` (+ the dashboard) with nohup — there is
  no autostart, and after a container recreation you re-start the process (the
  install and config persist). Its dashboard is self-authenticated via the
  plain `HERMES_USERNAME` / `HERMES_PASSWORD` creds and reachable at
  `9229:9119` (local stack).
  The personal sandbox also exposes opencode's dashboard on port `4096`
  (`opencode web --hostname 0.0.0.0 --port 4096`); no autostart.
- **Rebuild after changing the Dockerfile:** `docker compose -f
  compose.local.yaml build` then `docker compose -f compose.local.yaml up -d`.
  Tool state is preserved in the volume.
- **Full reset:** remove the container and its state volume
  (`infrastructure_<slug>-sandbox`), recreate it, then reinstall the tools you
  need inside it (see the Common commands block).

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
