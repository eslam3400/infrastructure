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
PostgreSQL, MongoDB, Redis, RustFS) and the same sandbox image. The server
stack runs one shared `sandbox`; the local stack runs the three named
sandboxes (see below). Tools like Hermes Agent are installed inside a sandbox
as needed — they are not services of their own.

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
see [docs/README.md](docs/README.md).
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
| vectora  | claude-code, cursor-agent           |
| personal | gh, opencode, hermes                |

All sandboxes are idle toolboxes; enter one with
`docker compose -f compose.local.yaml exec <slug> bash`.
The base image already ships **Node.js 24 LTS**, git, curl, openssh-client,
nano, jq, ripgrep, less, unzip, xz, gnupg and procps — install anything else
inside the sandbox yourself. Handy one-liners:

| Tool         | Install inside the sandbox                                                            |
|--------------|----------------------------------------------------------------------------------------|
| claude-code  | `npm install -g @anthropic-ai/claude-code`                                             |
| opencode     | `curl -fsSL https://opencode.ai/install \| bash`                                        |
| cursor-agent | `curl https://cursor.com/install -fsS \| bash`                                          |
| kiro-cli     | `curl -fsSL https://cli.kiro.dev/install \| bash`                                       |
| gh           | download the latest `gh_*_linux_*.tar.gz` from cli/cli releases, or use its apt repo    |
| hermes       | `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash -- --non-interactive` |

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
state written there — `gh` auth, opencode sessions, kiro/claude/cursor state,
and **npm global installs** (the image
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

## Security model

- Sandboxes run **without** `privileged` and **without** Docker-in-Docker, so
  they cannot reach host devices or control the host Docker daemon.
- Each sandbox runs as **root inside the container** (uid 0), with your host
  group (gid 1000) and `umask 002`. That is container-local root: it does not
  grant host root, and the workspace directory and named state volume remain
  the only host data it touches.
- `HOST_WORKSPACES_PATH` is the only host data exposed; keep it free of secrets.
- Infrastructure secrets live in `.env` and are never mounted into sandboxes.
