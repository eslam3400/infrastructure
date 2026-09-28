#!/usr/bin/env bash
set -euo pipefail

# This script runs as the container entrypoint CMD (after docker-init.sh boots
# Docker-in-Docker). It does one-time provisioning, then keeps `hermes serve`
# alive. Binding 0.0.0.0 is required so `docker run -p` can reach the backend,
# and a non-loopback bind always demands an auth provider, so the credentials
# are passed in from run.sh via HERMES_DASHBOARD_BASIC_AUTH_* env vars.

PROJECT_DIR="$(pwd)"
POST_CREATE="${PROJECT_DIR}/.devcontainer/post-create.sh"
# Sentinel lives on the container's ephemeral filesystem (not the workspace
# bind mount), so provisioning re-runs when the container is recreated but is
# skipped on a plain restart of the same container.
PROVISIONED_MARKER="/run/.devcontainer-provisioned"

if [ ! -f "$PROVISIONED_MARKER" ]; then
  # Wait (up to ~60s) for the workspace mount to be visible, then provision.
  for _ in $(seq 1 60); do
    [ -f "$POST_CREATE" ] && break
    sleep 1
  done
  if [ -f "$POST_CREATE" ]; then
    echo "[start-serve] running one-time post-create provisioning..."
    bash "$POST_CREATE" || echo "[start-serve] post-create failed; continuing"
    touch "$PROVISIONED_MARKER"
  else
    echo "[start-serve] post-create.sh not found at ${POST_CREATE}; skipping"
  fi
fi

trap 'echo "[start-serve] stopping hermes serve"; exit 0' TERM INT
while true; do
  echo "[start-serve] starting hermes serve on 0.0.0.0:9119"
  hermes serve --host 0.0.0.0 --port 9119 || echo "[start-serve] hermes serve exited ($?); restarting in 5s"
  sleep 5
done
