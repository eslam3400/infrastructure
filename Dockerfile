ARG UBUNTU_TAG=24.04
FROM ubuntu:${UBUNTU_TAG}

# Sandboxes run as root (uid 0) with the host user's group (1000, set in the
# compose files) and umask 002, so files written into the bind-mounted
# workspaces are root:eslam and group-writable — they stay editable and
# committable from the host as the normal user.
RUN printf 'umask 002\n' >> /etc/bash.bashrc \
  && printf 'umask 002\n' > /etc/profile.d/00-umask.sh
