#!/usr/bin/env bash
set -euo pipefail

# Workspace sandbox for the flyakeed repos. Each repo ships its own image:
# corp (Node 18.20 + pnpm 10.34), laravel (PHP 8.4 FrankenPHP/Octane, MySQL 8,
# Redis), os (PHP 8.4 Apache plus the observability compose stack).

sudo apt-get update
sudo apt-get install -y --no-install-recommends openssh-client ca-certificates
sudo rm -rf /var/lib/apt/lists/*

# Fresh key for this container. Add the printed public key to GitHub. The repo
# remote uses the flyakeed-github host alias; origin is HTTPS, rewritten below
# so fetch/push uses this key.
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "flyakeed-sandbox"
fi
cat > ~/.ssh/config <<'EOF'
Host flyakeed-github github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts 2>/dev/null || true

git config --global url."git@flyakeed-github:".insteadOf "https://github.com/"

cat <<EOF

Sandbox ready.
Add this public key to GitHub, then git fetch will work:

$(cat ~/.ssh/id_ed25519.pub)

Run the stacks:
  corp:     docker build -t akeed-corp . && docker run --rm -it akeed-corp
  os:       docker compose up -d
  laravel:  docker compose -f compose.dev.yaml up
EOF
