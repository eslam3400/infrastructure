#!/usr/bin/env bash
set -euo pipefail

devcontainer build --workspace-folder .

# Clean up existing container
docker rm -f flyakeed-sandbox 2>/dev/null || true

docker run -d \
  --name flyakeed-sandbox \
  --privileged \
  --restart unless-stopped \
  -v /home/eslam/work/flyakeed:/workspaces/flyakeed \
  -v flyakeed-sandbox-docker:/var/lib/docker \
  -v flyakeed-sandbox-containerd:/var/lib/containerd \
  -w /workspaces/flyakeed \
  --entrypoint /usr/local/share/docker-init.sh \
  flyakeed-sandbox \
  sleep infinity

# Run post-create setup (SSH key, tools); raw docker run skips the devcontainer lifecycle
docker exec flyakeed-sandbox bash /workspaces/flyakeed/.devcontainer/post-create.sh
