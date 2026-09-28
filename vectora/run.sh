#!/usr/bin/env bash
set -euo pipefail

devcontainer build --workspace-folder .

# Clean up existing container
docker rm -f vectora-sandbox 2>/dev/null || true

# Publish the Hermes backend on a host port unique to this sandbox, bound to
# loopback only so it stays off the LAN. Desktop connects to
# http://127.0.0.1:9224 as a Remote gateway.
docker run -d \
  --name vectora-sandbox \
  --privileged \
  --restart unless-stopped \
  -p 127.0.0.1:9224:9119 \
  -v /home/eslam/work/vectora:/workspaces/vectora \
  -v vectora-sandbox-docker:/var/lib/docker \
  -v vectora-sandbox-containerd:/var/lib/containerd \
  -v vectora-sandbox-home:/root \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=eslam \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=eslam \
  -w /workspaces/vectora \
  --entrypoint /usr/local/share/docker-init.sh \
  vectora-sandbox \
  bash /workspaces/vectora/.devcontainer/start-serve.sh

# start-serve.sh provisions the sandbox (post-create) on first boot, then keeps
# `hermes serve` running and restarting, so nothing else is needed here.
