# syntax=docker/dockerfile:1
# Arch + mise agent sandbox, shimmed from omaterm.
ARG OMATERM_BASE=ghcr.io/omacom-io/omaterm@sha256:180f5884ab8573b1235595eeefef605ad10ffdfbdef9eb96dfebd801e0f9215a
FROM ${OMATERM_BASE}

ARG OPENCODE_VERSION=1.18.21

ENV OPENCODE_PORT=4096 \
    MISE_DATA_DIR=/home/omaterm/.local/share/mise \
    MISE_CACHE_DIR=/home/omaterm/.local/cache/mise \
    MISE_CONFIG_DIR=/home/omaterm/.config/mise

# Pin the OpenCode release while using the image user's trusted mise config.
USER 1000
RUN mise use -g -y "opencode@${OPENCODE_VERSION}" \
    && opencode --version | grep -F "${OPENCODE_VERSION}" \
    && install -m 0755 "$(mise where opencode)/opencode" /tmp/omashiki-opencode-bin

USER root
RUN install -m 0755 /tmp/omashiki-opencode-bin /usr/local/bin/opencode \
    && rm /tmp/omashiki-opencode-bin
COPY entrypoint.sh /entrypoint.sh
COPY supply-chain-relay.py /usr/local/bin/supply-chain-relay
RUN chmod +x /entrypoint.sh /usr/local/bin/supply-chain-relay

# The runtime redirects mise data to a fresh cache. Keep the pinned binary
# ahead of the inherited mise shim so OpenCode boots before that cache fills.
ENV PATH="/usr/local/bin:${PATH}" \
    MISE_CONFIG_DIR=/tmp/agent-home/.config/mise

EXPOSE 4096

USER 1000:1000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${OPENCODE_PORT}/doc" >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
