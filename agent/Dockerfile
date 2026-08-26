# syntax=docker/dockerfile:1
# OpenCode agent sandbox.
#
# Built on debian:13-slim rather than the omaterm base, following the recipe
# Dockerfile.jcode already proves in this repo. omaterm is a workstation image:
# it ships a full Arch toolchain (LLVM, gcc, rustc, clang, guile, perl) plus
# omadots and a tmux-wired .bashrc, none of which a sandbox executes. Of its
# 6.47GB, 1.34GB is a `mise use -g` of every language runtime — and those are
# duplicated anyway, because omashiki.toml redirects MISE_DATA_DIR to
# /omashiki-cache/global/mise/data at runtime.
#
# What the sandbox actually needs is derived from entrypoint.sh: bash, git,
# curl (the HEALTHCHECK), python3 (supply-chain-relay), the mise *binary*
# (omashiki.toml pre_steps run `mise install --yes`) and opencode itself. The
# toolchains mise installs come from the mounted cache, not from this image.
ARG MISE_VERSION=2026.6.11
ARG OPENCODE_VERSION=1.18.21

FROM debian:13-slim AS mise

ARG MISE_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64.tar.gz" \
         -o /tmp/mise.tar.gz \
    && tar -xzf /tmp/mise.tar.gz -C /tmp \
    && install -m 0755 /tmp/mise/bin/mise /usr/local/bin/mise \
    && rm -rf /tmp/mise.tar.gz /tmp/mise \
    && rm -rf /var/lib/apt/lists/* \
    && /usr/local/bin/mise --version

# `mise use -g` unpacks the release into the mise data dir; installing the
# binary elsewhere does not free it. Only the binary crosses the boundary.
FROM mise AS opencode-build

ARG OPENCODE_VERSION

ENV MISE_DATA_DIR=/opt/mise-data \
    MISE_CACHE_DIR=/tmp/mise-cache \
    MISE_CONFIG_DIR=/opt/mise-config

RUN mise use -g -y "opencode@${OPENCODE_VERSION}" \
    && install -m 0755 "$(mise where opencode)/opencode" /tmp/omashiki-opencode-bin \
    && /tmp/omashiki-opencode-bin --version | grep -F "${OPENCODE_VERSION}"

FROM debian:13-slim

ARG OPENCODE_VERSION

# curl stays (unlike Dockerfile.jcode, which purges it) because the
# HEALTHCHECK below shells out to it on every interval.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         bash ca-certificates curl git python3 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -c 'import asyncio'

# Matches the uid the orchestrator runs containers as.
RUN useradd --uid 1000 --create-home --shell /bin/bash omaterm

COPY --from=mise /usr/local/bin/mise /usr/local/bin/mise
COPY --from=opencode-build /tmp/omashiki-opencode-bin /usr/local/bin/opencode
RUN chmod 0755 /usr/local/bin/mise /usr/local/bin/opencode \
    && /usr/local/bin/mise --version \
    && /usr/local/bin/opencode --version | grep -F "${OPENCODE_VERSION}"

COPY entrypoint.sh /entrypoint.sh
COPY supply-chain-relay.py /usr/local/bin/supply-chain-relay
RUN chmod 0755 /entrypoint.sh /usr/local/bin/supply-chain-relay

# Defaults only: omashiki.toml's [caches.global.env] overrides all three at
# runtime so the toolchains land in the shared cache mount, not the container.
ENV OPENCODE_PORT=4096 \
    MISE_DATA_DIR=/home/omaterm/.local/share/mise \
    MISE_CACHE_DIR=/home/omaterm/.local/cache/mise \
    MISE_CONFIG_DIR=/tmp/agent-home/.config/mise \
    PATH="/usr/local/bin:${PATH}"

EXPOSE 4096

USER 1000:1000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${OPENCODE_PORT}/doc" >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
