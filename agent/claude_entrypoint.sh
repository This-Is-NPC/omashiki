#!/usr/bin/env bash
set -euo pipefail

HOME="${HOME:-/tmp/agent-home}"
export HOME

mkdir -p "$HOME" "$HOME/.claude"

git config --global user.name "${GIT_USER_NAME:-omashiki-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@omashiki.local}"

WORKDIR_PATH="$(pwd)"
REPO_ROOT="$(cd "$WORKDIR_PATH/../.." && pwd)"
git config --global --add safe.directory "$WORKDIR_PATH"
git config --global --add safe.directory "$REPO_ROOT"
git config --global --add safe.directory "$REPO_ROOT/.git"

CREDENTIALS_PATH="${CLAUDE_CREDENTIALS_PATH:-/run/omashiki/state/claude-credentials.json}"
if [ ! -f "$CREDENTIALS_PATH" ]; then
  printf '%s\n' "Claude Code credentials snapshot is unavailable" >&2
  exit 78
fi

chmod 0600 "$CREDENTIALS_PATH"
ln -s "$CREDENTIALS_PATH" "$HOME/.claude/.credentials.json"

# The container is intentionally kept idle; each turn is a separate Docker exec.
exec sleep infinity
