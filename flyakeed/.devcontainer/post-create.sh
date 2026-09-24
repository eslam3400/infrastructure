#!/usr/bin/env bash
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends openssh-client ca-certificates curl
rm -rf /var/lib/apt/lists/*

DEVCONTAINER_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
KEY_SRC="${DEVCONTAINER_DIR}/ssh/id_ed25519"
mkdir -p "${DEVCONTAINER_DIR}/ssh"
if [ ! -f "$KEY_SRC" ]; then
  ssh-keygen -t ed25519 -f "$KEY_SRC" -N "" -C "flyakeed-sandbox"
fi
chmod 600 "$KEY_SRC"
chmod 644 "${KEY_SRC}.pub"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
install -m 600 "$KEY_SRC" ~/.ssh/id_ed25519
install -m 644 "${KEY_SRC}.pub" ~/.ssh/id_ed25519.pub

cat > ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts 2>/dev/null || true

git config --global --add safe.directory '*'

cat <<EOF

Sandbox ready.
Add this public key to GitHub, then git fetch will work:

$(cat "${KEY_SRC}.pub")

Run the stacks:
  corp:     docker build -t akeed-corp . && docker run --rm -it akeed-corp
  os:       docker compose up -d
  laravel:  docker compose -f compose.dev.yaml up
EOF
