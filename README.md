# devtik workspace

A self-hosted development workspace built on two mutually exclusive Docker
Compose stacks and a set of disposable **sandbox** containers for AI agents.

- **`compose.yaml`** — the **server** stack. Everything is fronted by Traefik
  (Let's Encrypt HTTPS), reached by hostname under a single domain. It also
  runs one shared **sandbox** (no Traefik route).
- **`compose.local.yaml`** — the **local** stack. No Traefik; every service
  binds a plain localhost/host port. The three slug **sandboxes** live here
  only.

Both stacks include the same infrastructure services (Portainer, DBgate,
PostgreSQL, MongoDB, Redis, RustFS). Hermes Agent runs inside the `personal`
sandbox (see below), not as a service of its own.

## Repository layout

```
.
├── Dockerfile               # the sandbox base image: Node.js 24 LTS + basic tooling
├── compose.yaml             # server stack (Traefik + infra, no sandboxes)
├── compose.local.yaml       # local stack (host ports + infra + sandboxes)
└── docs/
    ├── README.md            # service tables, replication guide, DNS, TLS
    ├── INTEGRATION.md       # how a separate app joins the stack network
    └── AGENTS.md            # guidance for AI agents working on this repo
```

## Quickstart

### Local

```bash
cp .env.example .env      # fill in DOMAIN only if you need it; local stack ignores TLS
docker compose -f compose.local.yaml build    # shared sandbox-base image (layer-cached, one real build)
docker compose -f compose.local.yaml up -d    # infra + the three sandboxes
docker compose -f compose.local.yaml exec flyakeed-sandbox bash   # enter and install what you need
```

### Server

```bash
cp .env.example .env && nano .env    # DOMAIN, ACME_EMAIL, credentials
docker compose build                 # shared sandbox-base image (layer-cached with local)
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

The server stack (compose.yaml) also runs a single shared `sandbox`
(workspace `${HOST_WORKSPACES_PATH}` mounted at `/workspaces/sandbox`). It
has no Traefik route — enter it with `docker compose exec sandbox bash`.

| Sandbox  | Typical tools (install as needed)          | Live process         | Local port    |
|----------|--------------------------------------------|----------------------|---------------|
| flyakeed | gh, kiro-cli                               | idle                 | —             |
| vectora  | claude-code, cursor-agent                  | idle                 | —             |
| personal | gh, opencode, hermes                       | hermes gateway :9119 | `9229 → 9119` |
| personal | (opencode dashboard, port exposed)         | opencode web :4096   | `4096 → 4096` |

All sandboxes are idle toolboxes; enter one with
`docker compose -f compose.local.yaml exec <slug>-sandbox bash`.
The base image already ships **Node.js 24 LTS**, git, curl, openssh-client and
nano — install anything else inside the sandbox yourself. Handy one-liners:

| Tool         | Install inside the sandbox                                                            |
|--------------|----------------------------------------------------------------------------------------|
| claude-code  | `npm install -g @anthropic-ai/claude-code`                                             |
| opencode     | `curl -fsSL https://opencode.ai/install \| bash`                                        |
| cursor-agent | `curl https://cursor.com/install -fsS \| bash`                                          |
| kiro-cli     | `curl -fsSL https://cli.kiro.dev/install \| bash`                                       |
| gh           | download the latest `gh_*_linux_*.tar.gz` from cli/cli releases, or use its apt repo    |
| hermes       | `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash -- --non-interactive` |

The personal sandbox's Hermes gateway runs **inside** the sandbox; after
installing, start it with
`nohup hermes gateway run >>~/.hermes/gateway.log 2>&1 &`
(plus the dashboard if wanted). After a container recreation the tool and its
config are still there — just start the process again.

The personal sandbox also exposes **opencode's dashboard** on port 4096. Start
it inside the sandbox with:
```bash
docker compose -f compose.local.yaml exec personal-sandbox opencode web --hostname 0.0.0.0 --port 4096
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

Each sandbox mounts a named volume at `/root` (its home). Credentials and tool
state written there — `gh` auth, opencode sessions, kiro/claude/cursor state,
hermes config/sessions (`~/.hermes`), and **npm global installs** (the image
sets npm's prefix to `/root/.local`, so `npm i -g` lands in the volume) —
**survives container destruction and recreation**. Nothing needs
re-authentication or re-configuration after a recreate.

To wipe a sandbox back to a clean slate (container + its state volume):

```bash
# sandboxes live in the local stack
docker compose -f compose.local.yaml rm -sf personal-sandbox
docker volume rm infrastructure_personal-sandbox
docker compose -f compose.local.yaml up -d personal-sandbox
```

Everything installed under `/root` (and anything installed at image build
time) is gone after the volume removal — reinstall the tools you need.

The workspace bind mount and all infrastructure data are left untouched.

### Getting into a sandbox

```bash
# sandboxes live in the local stack:
docker compose -f compose.local.yaml exec flyakeed-sandbox bash
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
