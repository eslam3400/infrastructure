#!/usr/bin/env bash
set -euo pipefail

devcontainer build --workspace-folder .

# Clean up existing container
docker rm -f devtik-sandbox 2>/dev/null || true

# Publish the Hermes backend on a host port unique to this sandbox, bound to
# loopback only so it stays off the LAN. Desktop connects to
# http://127.0.0.1:9221 as a Remote gateway.
docker run -d \
  --name devtik-sandbox \
  --privileged \
  --restart unless-stopped \
  -p 127.0.0.1:9221:9119 \
  -v /home/eslam/work/devtik:/workspaces/devtik \
  -v devtik-sandbox-docker:/var/lib/docker \
  -v devtik-sandbox-containerd:/var/lib/containerd \
  -v devtik-sandbox-home:/root \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=eslam \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=eslam \
  -w /workspaces/devtik \
  --entrypoint /usr/local/share/docker-init.sh \
  devtik-sandbox \
  bash /workspaces/devtik/.devcontainer/start-serve.sh

# start-serve.sh provisions the sandbox (post-create) on first boot, then keeps
# `hermes serve` running and restarting, so nothing else is needed here.
