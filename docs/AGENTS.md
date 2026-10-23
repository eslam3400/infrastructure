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
cp .env.example .env && nano .env        # DOMAIN, credentials

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
docker compose -f compose.local.yaml exec personal bash

# Wipe a sandbox's state volume and recreate it (flyakeed|vectora|personal)
docker compose -f compose.local.yaml rm -sf personal
docker volume rm workspace_personal_data
docker compose -f compose.local.yaml up -d personal

# Validate either compose file
docker compose config -q
docker compose -f compose.local.yaml config -q

# Tear down
docker compose down            # server stack
docker compose -f compose.local.yaml down   # local stack
```

There are **two mutually exclusive stacks**: `compose.yaml` (server) and
`compose.local.yaml` (local). Each pins its own project name via the top-level
`name:` key (`infrastructure` server, `workspace` local), so each stack owns
its own network and volumes — **never run both at once on the same host**;
stop one before starting the other. `compose.yaml` uses the default filename, so
`docker compose` finds it with no `-f` flag.

## Architecture & invariants

Two stacks (never run both at once on the same host):

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
  `portainer.${DOMAIN}` / `dbgate.${DOMAIN}` (443).
- **Data:** `postgres`, `mongodb`, `redis`, `rustfs` — each with a healthcheck.
  The databases use **TCP routers with `HostSNI` + TLS termination** on their
  own entrypoints; `rustfs` uses HTTP routers (`s3.${DOMAIN}`, `storage.${DOMAIN}`).
- **Sandbox:** `sandbox` — one idle toolbox (builds `sandbox:latest`
  from the root Dockerfile, same as the local sandboxes; mounts
  `${HOST_WORKSPACES_PATH}` at `/workspaces/sandbox`). No Traefik route and
  no published ports; enter it with `docker compose exec sandbox bash`.

Server routing is hostname-based, so **every service needs a DNS A record**
(`traefik`, `portainer`, `dbgate`, `storage`, `s3`,
`postgres`, `mongodb`, `redis` — all under `${DOMAIN}`, all pointing at the
host's public IP).

## Sandboxes

All three local sandboxes share the root `Dockerfile` (tag
`sandbox:latest`, based on the **latest Node.js LTS** — currently
`node:24-alpine`); there is no devcontainer and no Docker-in-Docker. The slug
services (`flyakeed`, `vectora`, `personal`) are
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
  only host data they see is the workspace directory: the local sandboxes
  mount `${HOST_WORKSPACES_PATH}/<slug>` at `/workspace`, and the server
  `sandbox` mounts `${HOST_WORKSPACES_PATH}` at `/workspaces/sandbox`. Never
  add a mount of a path that
  could contain secrets (e.g. `$HOME`, this repo's `.env`).
- **Persistent state:** each local sandbox mounts the named volume
  `<slug>_data` at `/root` (HOME). Credentials and tool state written
  there — gh auth, opencode sessions (`~/.opencode`), kiro/claude/cursor
  state, and npm global installs (the image
  sets npm's prefix to `/root/.local`, so `npm i -g` lands in the volume) —
  **survives container destruction and recreation**. Nothing needs
  re-auth or reinstall after a recreate. Note: anything installed via
  `apk` at *runtime* (not baked into the Dockerfile) lives in the container's
  ephemeral layer and does NOT survive — bake recurring needs into the
  Dockerfile instead.
- **All three sandboxes are idle** (`command: sleep infinity`); enter them with
  `docker compose -f compose.local.yaml exec <slug> bash`. Tools are not
  autostarted — install what you need inside a sandbox and start it manually;
  after a container recreation the install and config persist (they live in
  the volume), just start the process again.
- **Rebuild after changing the Dockerfile:** `docker compose -f
  compose.local.yaml build` then `docker compose -f compose.local.yaml up -d`.
  Tool state is preserved in the volume.
- **Full reset:** remove the container and its state volume
  (`workspace_<slug>_data`), recreate it, then reinstall the tools you
  need inside it (see the Common commands block).

## Key invariants to preserve when editing infrastructure

- **All persistent infra data is in Compose-managed named volumes** declared in
  the top-level `volumes:` block of *both* compose files (server project
  `infrastructure` → names `infrastructure_<volume>`; local project
  `workspace` → names `workspace_<volume>`). Any new
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
