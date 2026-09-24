#!/usr/bin/env bash
set -euo pipefail

devcontainer build --workspace-folder .

# Clean up existing container
docker rm -f devtik-sandbox 2>/dev/null || true

docker run -d \
  --name devtik-sandbox \
  --privileged \
  --restart unless-stopped \
  -v /home/eslam/work/devtik:/workspaces/devtik \
  -v devtik-sandbox-docker:/var/lib/docker \
  -v devtik-sandbox-containerd:/var/lib/containerd \
  -w /workspaces/devtik \
  --entrypoint /usr/local/share/docker-init.sh \
  devtik-sandbox \
  sleep infinity

# Run post-create setup (SSH key, tools); raw docker run skips the devcontainer lifecycle
docker exec devtik-sandbox bash /workspaces/devtik/.devcontainer/post-create.sh
