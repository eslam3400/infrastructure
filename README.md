# devtik workspace

A self-hosted development workspace built on two mutually exclusive Docker
Compose stacks and a set of disposable **sandbox** containers for AI agents.

- **`compose.yaml`** — the **server** stack. Everything is fronted by Traefik
  (Let's Encrypt HTTPS), reached by hostname under a single domain.
- **`compose.local.yaml`** — the **local** stack. No Traefik; every service
  binds a plain localhost/host port.

Both stacks include the same infrastructure services (Portainer, DBgate,
PostgreSQL, MongoDB, Redis, RustFS) and the same three sandboxes. Hermes Agent
runs inside the `personal` sandbox (see below), not as a service of its own.

## Repository layout

```
.
├── Dockerfile               # the sandbox image — builds all three sandboxes
├── compose.yaml             # server stack (Traefik + infra + sandboxes)
├── compose.local.yaml       # local stack (host ports + infra + sandboxes)
├── .env.example             # secrets/domain template — copy to .env
├── setup.sh                 # install selected tools into a sandbox container
└── docs/
    ├── README.md            # service tables, replication guide, DNS, TLS
    ├── INTEGRATION.md       # how a separate app joins the stack network
    └── AGENTS.md            # guidance for AI agents working on this repo
```

## Quickstart

### Local

```bash
cp .env.example .env      # fill in DOMAIN only if you need it; local stack ignores TLS
docker compose -f compose.local.yaml build
docker compose -f compose.local.yaml up -d
./setup.sh flyakeed node gh kiro            # flyakeed tools
./setup.sh vectora node claude cursor       # vectora tools
./setup.sh personal node gh opencode hermes # personal tools + hermes gateway
```

### Server

```bash
cp .env.example .env && nano .env    # DOMAIN, ACME_EMAIL, credentials
docker compose build
docker compose up -d
```

Install Docker and open the ports you need in your firewall (80/443, plus the
DB TCP ports for remote clients). The Traefik dashboard hash and the plain
Hermes credentials are set by hand — see [docs/README.md](docs/README.md).
Create the DNS A records (all under `${DOMAIN}`) before deploying so Let's
Encrypt can issue certificates.

## Sandboxes

Sandboxes are disposable playgrounds where an AI agent can do anything: if it
breaks something, recreate the container. They run as **unprivileged**
containers with no Docker-in-Docker, so they cannot touch host devices or the
Docker socket. The only host data they can see is the directory mounted as
their workspace.

| Sandbox  | Tools (pick via `./setup.sh`)              | Live process         | Local port    | Server route                          |
|----------|--------------------------------------------|----------------------|---------------|---------------------------------------|
| flyakeed | node 26 (nvm), gh, kiro-cli                | idle                 | —             | —                                     |
| vectora  | node 26 (nvm), claude-code, cursor-agent   | idle                 | —             | —                                     |
| personal | node 26 (nvm), gh, opencode, hermes        | hermes gateway :9119 | `9229 → 9119` | `https://hermes.personal.${DOMAIN}`   |
| personal | (opencode dashboard, port exposed)         | opencode web :4096   | `4096 → 4096` | `https://opencode.personal.${DOMAIN}` |

All sandboxes are idle toolboxes; enter one with `docker compose exec <slug>-sandbox bash`.
Tools are installed on demand with `./setup.sh <slug> <tool>...` (one shared
script — run `./setup.sh` to print the tool list). The personal sandbox's
Hermes gateway runs **inside** the sandbox: `./setup.sh personal hermes`
installs it and starts `hermes gateway run` + the dashboard; after the
container is recreated, re-run that command to start them again.

The personal sandbox also exposes **opencode's dashboard** on port 4096. Start
it inside the sandbox with:
```bash
docker compose exec personal-sandbox opencode web --hostname 0.0.0.0 --port 4096
```
then open `http://localhost:4096` (local stack). It binds `0.0.0.0`, so anyone
who can reach the host port can use it — set `OPENCODE_SERVER_PASSWORD` to
require basic auth (`OPENCODE_SERVER_USERNAME` defaults to `opencode`).

Inside a sandbox you are **root** (uid 0), running with your host user's group
(gid 1000) and `umask 002`. So files created in the bind-mounted workspace —
including git commits — are `root:eslam` and group-writable: you can edit and
commit from the sandbox or the host as your normal user, interchangeably.

### Workspaces

Each sandbox bind-mounts a host directory set by an env var
(`FLYAKEED_WORKSPACES_PATH`, `VECTORA_WORKSPACES_PATH`,
`PERSONAL_WORKSPACES_PATH`). Point these at directories that contain **nothing
sensitive** — the AI can read and write everything under the path.

### Persistent state

Each sandbox mounts a named volume at `/root` (its home). Tool state
written there — `gh` auth, opencode sessions, kiro/claude/cursor state, hermes
config/sessions (`~/.hermes`), nvm + node (`~/.nvm`) — **survives container
destruction and recreation**. Tools are installed at runtime by
`./setup.sh <slug> <tool>...` (idempotent — safe to re-run).

To wipe a sandbox back to a clean slate (container + its state volume), then
reinstall its tools:

```bash
# server stack (add `-f compose.local.yaml` for the local stack)
docker compose rm -sf personal-sandbox
docker volume rm infrastructure_personal-sandbox
docker compose up -d personal-sandbox
./setup.sh personal node gh opencode hermes
```

The workspace bind mount and all infrastructure data are left untouched.

### Getting into a sandbox

```bash
docker compose exec flyakeed-sandbox bash
# or for the local stack:
docker compose -f compose.local.yaml exec vectora-sandbox bash
```

## Security model

- Sandboxes run **without** `privileged` and **without** Docker-in-Docker, so
  they cannot reach host devices or control the host Docker daemon.
- Each sandbox runs as **root inside the container** (uid 0), with your host
  group (gid 1000) and `umask 002`. That is container-local root: it does not
  grant host root, and the workspace directory and named state volume remain
  the only host data it touches.
- `*_WORKSPACES_PATH` is the only host data exposed; keep it free of secrets.
- Infrastructure secrets live in `.env` and are never mounted into sandboxes.
