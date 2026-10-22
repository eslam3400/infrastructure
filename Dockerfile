FROM node:24

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      nano \
      jq \
      ripgrep \
      less \
      unzip \
      xz-utils \
      gnupg \
      procps \
      libatomic1 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN npm config set prefix /root/.local
ENV PATH=/root/.local/bin:$PATH
