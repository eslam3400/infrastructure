ARG UBUNTU_MIRROR=http://mirrors.edge.kernel.org/ubuntu/

FROM ubuntu:24.04

ARG UBUNTU_MIRROR

# archive.ubuntu.com is DNS-hijacked by lancache on this LAN (192.168.1.146).
# It caches Packages.gz by URL and serves a stale body against a fresh Release
# file, so apt aborts with "File has unexpected size" and feature installs fail.
# Point the archive at a mirror lancache does not intercept.
RUN sed -i "s|http://archive.ubuntu.com/ubuntu/|${UBUNTU_MIRROR}|" /etc/apt/sources.list.d/ubuntu.sources

# The node feature's nvm install can fail its checksum lookup for the prebuilt
# binary and fall back to compiling Node from source. Ubuntu 24.04 ships only
# `python3` (no `python` symlink), so that source build's ./configure fails
# with "exec: python: not found" unless we provide it up front.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python-is-python3 make g++ \
 && rm -rf /var/lib/apt/lists/*
