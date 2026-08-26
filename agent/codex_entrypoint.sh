#!/usr/bin/env bash
set -euo pipefail

HOME="${HOME:-/tmp/agent-home}"
export HOME

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
export CODEX_HOME

mkdir -p "$HOME" "$CODEX_HOME"

git config --global user.name "${GIT_USER_NAME:-omashiki-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@omashiki.local}"

WORKDIR_PATH="$(pwd)"
REPO_ROOT="$(cd "$WORKDIR_PATH/../.." && pwd)"
git config --global --add safe.directory "$WORKDIR_PATH"
git config --global --add safe.directory "$REPO_ROOT"
git config --global --add safe.directory "$REPO_ROOT/.git"

CREDENTIALS_PATH="${CODEX_CREDENTIALS_PATH:-/run/omashiki/state/codex-auth.json}"
if [ ! -f "$CREDENTIALS_PATH" ]; then
  printf '%s\n' "Codex credentials snapshot is unavailable" >&2
  exit 78
fi

chmod 0600 "$CREDENTIALS_PATH"
ln -s "$CREDENTIALS_PATH" "$CODEX_HOME/auth.json"

# The container is intentionally kept idle; each turn is a separate Docker exec.
exec sleep infinity
