#!/usr/bin/env bash
set -euo pipefail

devcontainer build --workspace-folder .

# Clean up existing container
docker rm -f vectora-sandbox 2>/dev/null || true

docker run -d \
  --name vectora-sandbox \
  --privileged \
  --restart unless-stopped \
  -v /home/eslam/work/vectora:/workspaces/vectora \
  -v vectora-sandbox-docker:/var/lib/docker \
  -v vectora-sandbox-containerd:/var/lib/containerd \
  -w /workspaces/vectora \
  --entrypoint /usr/local/share/docker-init.sh \
  vectora-sandbox \
  sleep infinity