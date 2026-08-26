#!/usr/bin/env bash
set -euo pipefail

HOME="${HOME:-/tmp/agent-home}"
export HOME

JCODE_HOME="${JCODE_HOME:-$HOME/.jcode}"
export JCODE_HOME

mkdir -p "$HOME" "$JCODE_HOME"

git config --global user.name "${GIT_USER_NAME:-omashiki-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@omashiki.local}"

WORKDIR_PATH="$(pwd)"
REPO_ROOT="$(cd "$WORKDIR_PATH/../.." && pwd)"
git config --global --add safe.directory "$WORKDIR_PATH"
git config --global --add safe.directory "$REPO_ROOT"
git config --global --add safe.directory "$REPO_ROOT/.git"

# The container never holds a provider key. The orchestrator writes a
# job-bound gateway token here and points jcode at the loopback gateway, so the
# profile below can only reach Omashiki, and only for this job.
if [ -z "${JCODE_GATEWAY_TOKEN:-}" ]; then
  printf '%s\n' "jcode gateway token is unavailable" >&2
  exit 78
fi

if [ -z "${JCODE_GATEWAY_BASE_URL:-}" ] || [ -z "${JCODE_GATEWAY_MODEL:-}" ]; then
  printf '%s\n' "jcode requires JCODE_GATEWAY_BASE_URL and JCODE_GATEWAY_MODEL" >&2
  exit 78
fi

# --api-key-env stores only the variable *name*, so the token never lands on
# disk and every `docker exec` turn resolves it fresh from the environment.
# (--api-key-stdin would persist it to a private env file that a later exec does
# not load, which fails with JCODE_PROVIDER_OMASHIKI_API_KEY not found.)
# --no-update because a release build otherwise phones home on every start.
jcode provider add omashiki \
  --base-url "${JCODE_GATEWAY_BASE_URL}" \
  --model "${JCODE_GATEWAY_MODEL}" \
  --api-key-env JCODE_GATEWAY_TOKEN \
  --auth bearer \
  --set-default \
  --no-update \
  --quiet \
  --json > /dev/null

# The container is intentionally kept idle; each turn is a separate Docker exec.
exec sleep infinity
