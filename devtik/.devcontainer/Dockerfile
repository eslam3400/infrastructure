ARG UBUNTU_MIRROR=http://mirrors.edge.kernel.org/ubuntu/

FROM ubuntu:24.04

ARG UBUNTU_MIRROR

# archive.ubuntu.com is DNS-hijacked by lancache on this LAN (192.168.1.146).
# It caches Packages.gz by URL and serves a stale body against a fresh Release
# file, so apt aborts with "File has unexpected size" and feature installs fail.
# Point the archive at a mirror lancache does not intercept.
RUN sed -i "s|http://archive.ubuntu.com/ubuntu/|${UBUNTU_MIRROR}|" /etc/apt/sources.list.d/ubuntu.sources
