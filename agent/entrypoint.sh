#!/usr/bin/env bash
set -euo pipefail

# --- Environment ---
# OPENCODE_CONFIG_CONTENT — task-scoped config override loaded by OpenCode
# OPENCODE_CONFIG_PATH    — read-only host config snapshot mounted by the runtime
# OPENCODE_AUTH_PATH      — path to a tmpfs file holding the auth JSON; copied to
#                           $HOME/.local/share/opencode/auth.json with 0600
# OPENCODE_PORT           — TCP port to bind (default 4096)
# HOME                    — overridden by the orchestrator to a tmpfs path so
#                           opencode's config/auth dirs are writable on a
#                           readonly rootfs container
# GIT_USER_NAME / GIT_USER_EMAIL — git author identity for commits the agent makes

PORT="${OPENCODE_PORT:-4096}"
HOME="${HOME:-/tmp/agent-home}"
export HOME

mkdir -p "$HOME"

git config --global user.name "${GIT_USER_NAME:-omashiki-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@omashiki.local}"
# The workspace is bind-mounted from the host. Restrict the git
# safe.directory exception to the WORKDIR (the agent's worktree) and its
# parent repo root — never `*` — so a hostile worktree cannot trick git
# into trusting unrelated paths.
WORKDIR_PATH="$(pwd)"
git config --global --add safe.directory "$WORKDIR_PATH"
# Walk two levels up to reach the repo root (worktrees live at
# <repo>/.omashiki-worktrees/group-<id>).
REPO_ROOT="$(cd "$WORKDIR_PATH/../.." && pwd)"
git config --global --add safe.directory "$REPO_ROOT"
git config --global --add safe.directory "$REPO_ROOT/.git"

mkdir -p "$HOME/.config/opencode"
if [ -n "${OPENCODE_CONFIG_PATH:-}" ] && [ -f "${OPENCODE_CONFIG_PATH}" ]; then
  cp "${OPENCODE_CONFIG_PATH}" "$HOME/.config/opencode/opencode.json"
fi

# Auth secret is bind-mounted `:ro` from a host tmpfs file at the path
# pointed to by OPENCODE_AUTH_PATH. Copy it into opencode's expected
# location with mode 0600 so the upstream tool finds it where it looks.
if [ -n "${OPENCODE_AUTH_PATH:-}" ] && [ -f "${OPENCODE_AUTH_PATH}" ]; then
  mkdir -p "$HOME/.local/share/opencode"
  ( umask 077 && cp "${OPENCODE_AUTH_PATH}" "$HOME/.local/share/opencode/auth.json" )
  chmod 0600 "$HOME/.local/share/opencode/auth.json"
fi

# An allowlisted container has no host or Internet route. Relay its localhost
# HTTP endpoint through the bind-mounted host Unix socket instead.
if [ -n "${OMASHIKI_HOST_SOCKET:-}" ]; then
  supply-chain-relay &
fi

# Direct harness/provider traffic gets a separate CONNECT-only host proxy.
if [ -n "${OMASHIKI_LLM_EGRESS_SOCKET:-}" ]; then
  OMASHIKI_HOST_SOCKET="${OMASHIKI_LLM_EGRESS_SOCKET}" \
    OMASHIKI_HOST_RELAY_PORT=8081 \
    supply-chain-relay &
fi

# Bind to all interfaces inside the container's network namespace; the
# orchestrator-side port mapping (`HostIp: 127.0.0.1`) restricts external
# reachability to host loopback.
exec opencode serve --port "${PORT}" --hostname 0.0.0.0
