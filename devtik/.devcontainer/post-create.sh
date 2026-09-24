#!/usr/bin/env bash
set -euo pipefail

# Workspace sandbox for the devtik repos. Stacks run inside Docker, not on this
# image: contactless-payments (Node 24 API, Node 20 dashboard, Postgres 18,
# Mongo 8) and dev-server (Traefik, Postgres 18, Mongo 8, Redis, RustFS).
# spot has no application files yet.

sudo apt-get update
sudo apt-get install -y --no-install-recommends openssh-client ca-certificates
sudo rm -rf /var/lib/apt/lists/*

# Fresh key for this container. Add the printed public key to GitHub. Existing
# remotes use the personal-github host alias, so the config covers that alias
# and github.com.
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "devtik-sandbox"
fi
cat > ~/.ssh/config <<'EOF'
Host personal-github github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts 2>/dev/null || true

cat <<EOF

Sandbox ready.
Add this public key to GitHub, then git fetch will work on the personal-github remotes:

$(cat ~/.ssh/id_ed25519.pub)

Run the stacks:
  contactless-payments:  docker compose -f docker-compose.local.yml up --build
  dev-server (local):    docker compose -f compose.local.yaml up -d
EOF
