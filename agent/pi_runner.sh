#!/usr/bin/env bash
# Runs exactly one turn from a prompt file.
#
# The prompt never crosses the Docker exec argv: the orchestrator hands over a
# path and composes the instruction/context text itself, so this script only
# reads a file. That also keeps the image free of a JSON parser — pi's
# newline-delimited event stream is folded host-side by the adapter.
set -euo pipefail

INVOCATION_PATH="${1:-}"

if [ "$INVOCATION_PATH" = "--version" ]; then
  exec pi --version
fi

if [ -z "$INVOCATION_PATH" ] || [ ! -f "$INVOCATION_PATH" ]; then
  printf '%s\n' "pi runner requires an invocation path" >&2
  exit 64
fi

shift || true

MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      MODEL="${2:-}"
      if [ -z "$MODEL" ]; then
        printf '%s\n' "pi runner requires a value for --model" >&2
        exit 64
      fi
      shift 2
      ;;
    *)
      printf '%s\n' "pi runner rejected option $1" >&2
      exit 64
      ;;
  esac
done

# The profile may pin a model; otherwise the credential's model, which is also
# the id declared in models.json, is the one to ask for.
if [ -z "$MODEL" ]; then
  MODEL="${PI_GATEWAY_MODEL:-}"
fi

if [ -z "$MODEL" ]; then
  printf '%s\n' "pi runner has no model to run" >&2
  exit 78
fi

PROMPT="$(cat "$INVOCATION_PATH")"

if [ -z "$PROMPT" ]; then
  printf '%s\n' "pi runner rejected an empty prompt" >&2
  exit 65
fi

# No --api-key: models.json resolves the token from the environment, so it never
# appears in this argv where `ps` inside the container would show it.
#
# The discovery flags are all off because the sandbox supplies the whole task:
# an AGENTS.md in the worktree, a skill, or an extension would silently change
# the prompt between attempts and is not something the job declared.
# `--` keeps a prompt that begins with a dash from being parsed as options.
exec pi \
  --provider omashiki \
  --model "$MODEL" \
  --offline \
  --print \
  --mode json \
  --no-session \
  --no-extensions \
  --no-skills \
  --no-context-files \
  -- "$PROMPT"
