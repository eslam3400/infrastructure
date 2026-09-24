#!/usr/bin/env bash
set -euo pipefail

# Workspace sandbox for vectora. integrations is a Node 24 / TypeScript service
# (NestJS 11, Postgres 17 via Supabase) with no Dockerfile or compose file yet.
# Node 24 is installed by the node feature before Claude Code, so `claude` uses
# that same runtime. The docker-in-docker feature starts the daemon used for
# `npx supabase start`.

sudo apt-get update
sudo apt-get install -y --no-install-recommends openssh-client ca-certificates curl
sudo rm -rf /var/lib/apt/lists/*

# One key for this workspace, stored next to this script so a container rebuild
# reuses it. Create it only when the file is absent.
DEVCONTAINER_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
KEY_SRC="${DEVCONTAINER_DIR}/ssh/id_ed25519"
mkdir -p "${DEVCONTAINER_DIR}/ssh"
if [ ! -f "$KEY_SRC" ]; then
  ssh-keygen -t ed25519 -f "$KEY_SRC" -N "" -C "vectora-sandbox"
fi
chmod 600 "$KEY_SRC"
chmod 644 "${KEY_SRC}.pub"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
install -m 600 "$KEY_SRC" ~/.ssh/id_ed25519
install -m 644 "${KEY_SRC}.pub" ~/.ssh/id_ed25519.pub
cat > ~/.ssh/config <<'EOF'
Host bitbucket.org
  HostName bitbucket.org
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh-keyscan -t ed25519,rsa bitbucket.org >> ~/.ssh/known_hosts 2>/dev/null || true
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts 2>/dev/null || true

# Cursor CLI. Official install from https://cursor.com/install
curl https://cursor.com/install -fsS | bash

cat <<EOF

Sandbox ready.
Claude Code: claude
Cursor CLI:  agent

Add this public key to Bitbucket once. Rebuilds reuse .devcontainer/ssh/id_ed25519:

$(cat "${KEY_SRC}.pub")

Node on this container is 24 ($(node -v)).
Run the stack once the service has a compose file, or start local Supabase:
  cd integrations && npx supabase start
EOF
