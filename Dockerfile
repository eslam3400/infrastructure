FROM node:24-alpine

RUN apk add --no-cache \
      curl \
      git \
      openssh-client \
      nano \
      jq \
      ripgrep \
      less \
      unzip \
      xz \
      gnupg \
      procps

RUN npm config set prefix /root/.local
ENV PATH=/root/.local/bin:$PATH
