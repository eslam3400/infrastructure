FROM node:26.13.0-alpine3.24

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

RUN npm install -g opencode-ai

EXPOSE 4096
