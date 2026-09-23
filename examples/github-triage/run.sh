#!/usr/bin/env bash
# The GitHub side of the triage recipe: the reference handler turns every new
# issue into a job for the triage environment. With SMEE_URL set, a smee.io
# client relays GitHub's webhook to the handler.
#
# Secrets come from the environment only:
#   OMASHIKI_TOKEN         token from `mix omashiki.token create --env triage`
#   GITHUB_WEBHOOK_SECRET  the secret set on the repository webhook
# Optional: OMASHIKI_URL (default http://127.0.0.1:4010), HANDLER_PORT
# (default 8090), SMEE_URL.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

for name in OMASHIKI_TOKEN GITHUB_WEBHOOK_SECRET; do
  if [ -z "${!name:-}" ]; then
    echo "run.sh: $name is required (see examples/github-triage/README.md)" >&2
    exit 1
  fi
done

export OMASHIKI_URL="${OMASHIKI_URL:-http://127.0.0.1:4010}"
export OMASHIKI_ENVIRONMENT=triage
export HANDLER_TRIGGER=opened
export HANDLER_INSTRUCTION="$here/triage.md"
export HANDLER_PORT="${HANDLER_PORT:-8090}"
# A none job takes no repository; admission refuses one.
unset OMASHIKI_REPO

if [ -n "${SMEE_URL:-}" ]; then
  npx --yes smee-client --url "$SMEE_URL" --target "http://127.0.0.1:$HANDLER_PORT/github" &
  smee_pid=$!
  trap 'kill "$smee_pid" 2>/dev/null' EXIT
fi

python3 "$here/../handler/github_issue_handler.py"
