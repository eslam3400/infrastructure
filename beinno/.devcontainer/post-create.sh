#!/usr/bin/env bash
set -euo pipefail

# Workspace sandbox for beinno. ahwa runs from its own Dockerfile (Node 22,
# Postgres 17, Redis 7, Caddy). wordpress is a VM-to-Docker migration plan
# (shared PHP-FPM, MariaDB, reverse proxy); there is no compose file yet.

sudo apt-get update
sudo apt-get install -y --no-install-recommends openssh-client ca-certificates
sudo rm -rf /var/lib/apt/lists/*

# Fresh key for this container. Add the printed public key to GitHub. The ahwa
# remote uses the personal-github host alias.
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "beinno-sandbox"
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
Add this public key to GitHub, then git fetch will work on the personal-github remote:

$(cat ~/.ssh/id_ed25519.pub)

Run the stack:
  ahwa: cd ahwa && docker compose -f compose.yml -f compose.dev.yml up --build
        # http://localhost:3000
EOF
