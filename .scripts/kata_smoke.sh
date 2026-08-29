#!/usr/bin/env bash
# Run one disposable, host-only Docker/Kata smoke container.

set -Eeuo pipefail

usage() {
  printf 'usage: %s [JCODE_IMAGE]\n' "$(basename "$0")" >&2
  exit 2
}

[ "$#" -le 1 ] || usage
IMAGE="${1:-${OMASHIKI_KATA_SMOKE_IMAGE:-omashiki/agent-jcode:ci-check}}"
for command in docker date python3; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'required command is missing: %s\n' "$command" >&2
    exit 1
  }
done

runtimes="$(docker info --format '{{json .Runtimes}}')" || {
  printf 'Docker is unavailable\n' >&2
  exit 1
}
python3 - "$runtimes" <<'PY'
import json
import sys

try:
    runtimes = json.loads(sys.argv[1])
except (IndexError, json.JSONDecodeError) as error:
    raise SystemExit(f"Docker returned invalid runtime data: {error}")
if not isinstance(runtimes, dict) or "kata" not in runtimes:
    raise SystemExit("Docker does not advertise runtime kata")
PY

docker image inspect "$IMAGE" >/dev/null || {
  printf 'jcode image is not available locally: %s\n' "$IMAGE" >&2
  exit 1
}

RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}"
LABEL_KEY="com.omashiki.kata-smoke"
LABEL_VALUE="$RUN_ID"
CONTAINER_NAME="omashiki-kata-smoke-$RUN_ID"
CONTAINER_ID=""

cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT INT TERM

  if [ -z "$CONTAINER_ID" ]; then
    local discovered
    if ! discovered="$(docker ps -aq --filter "label=${LABEL_KEY}=${LABEL_VALUE}" 2>/dev/null)"; then
      printf 'cleanup verification could not query Docker\n' >&2
      cleanup_status=1
      discovered=""
    fi
    if [ "$(printf '%s\n' "$discovered" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ]; then
      CONTAINER_ID="$(printf '%s\n' "$discovered" | awk 'NF { print; exit }')"
    elif [ -n "$discovered" ]; then
      printf 'cleanup refused: multiple containers carry this smoke label\n' >&2
      cleanup_status=1
    fi
  fi
  if [ -n "$CONTAINER_ID" ]; then
    docker rm -f "$CONTAINER_ID" >/dev/null || cleanup_status=1
  fi

  local remaining
  if ! remaining="$(docker ps -aq --filter "label=${LABEL_KEY}=${LABEL_VALUE}" 2>/dev/null)"; then
    printf 'cleanup verification could not query Docker\n' >&2
    cleanup_status=1
    remaining=""
  fi
  if [ -n "$remaining" ]; then
    printf 'cleanup verification failed; labelled container remains: %s\n' "$remaining" >&2
    cleanup_status=1
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf 'smoke cleanup failed; refusing success\n' >&2
    exit 1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Do not use --rm: explicit removal plus post-removal verification makes a
# failed cleanup visible instead of hiding it behind Docker's auto-removal.
CONTAINER_ID="$(docker run -d \
  --runtime kata \
  --name "$CONTAINER_NAME" \
  --label "${LABEL_KEY}=${LABEL_VALUE}" \
  --entrypoint /bin/sh \
  "$IMAGE" \
  -c 'printf kata-smoke-started; sleep 15')" || {
  printf 'could not start Kata smoke container\n' >&2
  exit 1
}

container_count="$(docker ps -aq --filter "label=${LABEL_KEY}=${LABEL_VALUE}" | awk 'NF { count++ } END { print count + 0 }')"
[ "$container_count" -eq 1 ] || {
  printf 'expected exactly one labelled smoke container, found %s\n' "$container_count" >&2
  exit 1
}

runtime="$(docker inspect --format '{{.HostConfig.Runtime}}' "$CONTAINER_ID")"
[ "$runtime" = "kata" ] || {
  printf 'container runtime mismatch: expected kata, got %s\n' "$runtime" >&2
  exit 1
}

command_output="$(docker exec "$CONTAINER_ID" /bin/sh -c 'printf kata-smoke-exec-ok')"
[ "$command_output" = "kata-smoke-exec-ok" ] || {
  printf 'container command execution check failed\n' >&2
  exit 1
}

printf 'Kata smoke passed: image=%s runtime=%s container=%s\n' "$IMAGE" "$runtime" "$CONTAINER_ID"
