#!/usr/bin/env bash
set -euo pipefail

devcontainer build --workspace-folder .

# Clean up existing container
docker rm -f beinno-sandbox 2>/dev/null || true

docker run -d \
  --name beinno-sandbox \
  --privileged \
  --restart unless-stopped \
  -v /home/eslam/work/beinno:/workspaces/beinno \
  -v beinno-sandbox-docker:/var/lib/docker \
  -v beinno-sandbox-containerd:/var/lib/containerd \
  -w /workspaces/beinno \
  --entrypoint /usr/local/share/docker-init.sh \
  beinno-sandbox \
  sleep infinity

# Run post-create setup (SSH key, tools); raw docker run skips the devcontainer lifecycle
docker exec beinno-sandbox bash /workspaces/beinno/.devcontainer/post-create.sh
