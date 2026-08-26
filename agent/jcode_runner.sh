#!/usr/bin/env bash
# Runs exactly one turn from a prompt file.
#
# The prompt never crosses the Docker exec argv: the orchestrator hands over a
# path and composes the instruction/context text itself, so this script only
# reads a file. That also keeps the image free of a JSON parser.
set -euo pipefail

INVOCATION_PATH="${1:-}"

if [ "$INVOCATION_PATH" = "--version" ]; then
  exec jcode --version
fi

if [ -z "$INVOCATION_PATH" ] || [ ! -f "$INVOCATION_PATH" ]; then
  printf '%s\n' "jcode runner requires an invocation path" >&2
  exit 64
fi

shift || true

MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      MODEL="${2:-}"
      if [ -z "$MODEL" ]; then
        printf '%s\n' "jcode runner requires a value for --model" >&2
        exit 64
      fi
      shift 2
      ;;
    *)
      printf '%s\n' "jcode runner rejected option $1" >&2
      exit 64
      ;;
  esac
done

PROMPT="$(cat "$INVOCATION_PATH")"

if [ -z "$PROMPT" ]; then
  printf '%s\n' "jcode runner rejected an empty prompt" >&2
  exit 65
fi

set -- --provider-profile omashiki run --json --quiet --no-update
if [ -n "$MODEL" ]; then
  set -- "$@" --model "$MODEL"
fi

exec jcode "$@" "$PROMPT"
