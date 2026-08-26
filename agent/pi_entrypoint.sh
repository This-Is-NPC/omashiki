#!/usr/bin/env bash
set -euo pipefail

HOME="${HOME:-/tmp/agent-home}"
export HOME

PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
export PI_CODING_AGENT_DIR

# Without this pi performs startup network operations against its model catalog
# and blocks indefinitely when that route is unavailable. In a restricted
# container that is a silent boot hang, not a slow start.
export PI_OFFLINE=1

mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"

git config --global user.name "${GIT_USER_NAME:-omashiki-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@omashiki.local}"

WORKDIR_PATH="$(pwd)"
REPO_ROOT="$(cd "$WORKDIR_PATH/../.." && pwd)"
git config --global --add safe.directory "$WORKDIR_PATH"
git config --global --add safe.directory "$REPO_ROOT"
git config --global --add safe.directory "$REPO_ROOT/.git"

# The container never holds a provider key. The orchestrator writes a job-bound
# gateway token into the environment and points pi at the loopback gateway, so
# the provider below can only reach Omashiki, and only for this job.
if [ -z "${PI_GATEWAY_TOKEN:-}" ]; then
  printf '%s\n' "pi gateway token is unavailable" >&2
  exit 78
fi

if [ -z "${PI_GATEWAY_BASE_URL:-}" ] || [ -z "${PI_GATEWAY_MODEL:-}" ]; then
  printf '%s\n' "pi requires PI_GATEWAY_BASE_URL and PI_GATEWAY_MODEL" >&2
  exit 78
fi

# Both values are interpolated into JSON below. They come from omashiki.toml,
# but a stray quote or backslash would silently rewrite the document — most
# damagingly `baseUrl` — so reject them rather than emit a broken provider.
case "${PI_GATEWAY_BASE_URL}${PI_GATEWAY_MODEL}" in
  *'"'* | *'\'*)
    printf '%s\n' "pi gateway base URL and model must not contain quotes or backslashes" >&2
    exit 78
    ;;
esac

# `"$PI_GATEWAY_TOKEN"` is written literally: pi resolves a leading `$` from the
# environment at request time. The token therefore never lands on disk, and
# every `docker exec` turn picks it up fresh — the same property jcode gets from
# --api-key-env.
#
# supportsDeveloperRole=false because pi otherwise sends the `developer` role
# for reasoning-capable models and llama.cpp rejects it.
umask 077
cat > "$PI_CODING_AGENT_DIR/models.json" <<EOF
{
  "providers": {
    "omashiki": {
      "baseUrl": "${PI_GATEWAY_BASE_URL}",
      "api": "openai-completions",
      "apiKey": "\$PI_GATEWAY_TOKEN",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false },
      "models": [{ "id": "${PI_GATEWAY_MODEL}" }]
    }
  }
}
EOF

# The container is intentionally kept idle; each turn is a separate Docker exec.
exec sleep infinity
