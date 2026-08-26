#!/usr/bin/env bash
# Agent image gate: size budget + runtime dependency contract.
#
#   .scripts/agent_image_check.sh IMAGE MAX_MB BINARY...
#
# Two regressions this catches, both of which build perfectly green:
#
#   Size. The agent images sat at 7.2-8.5GB because they inherited omaterm, a
#   workstation base carrying a full Arch toolchain the sandbox never invokes.
#   Nothing in a build log says "this image grew by 6GB", so a future base bump
#   or a stray `apt-get install build-essential` silently restores it. The
#   budget is asserted against the same figure `docker images` prints, which is
#   the one an operator reads.
#
#   Dependencies. entrypoint.sh needs bash, git, curl (the HEALTHCHECK shells
#   out to it) and python3 (supply-chain-relay); omashiki.toml pre_steps run
#   `mise install --yes`, so the mise *binary* has to be on PATH even though
#   the toolchains it installs come from the mounted cache. An image missing
#   any of these builds fine and then fails every job at runtime, which a size
#   assertion alone will not catch.
#
# Each binary is executed, not merely located. `command -v node` succeeds for a
# node(1) that cannot load libatomic.so.1 — debian-slim omits that library and
# node >= 26 links against it, so locating the file proves nothing.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") IMAGE MAX_MB BINARY..." >&2
  exit 2
}

[ "$#" -ge 3 ] || usage

IMAGE="$1"
MAX_MB="$2"
shift 2

fail=0

# --- size budget ---------------------------------------------------------
# `docker image inspect .Size` reports the compressed content size under the
# containerd image store, which is ~4x smaller than what `docker images`
# shows. Read the human column so the budget means what the table means.
human="$(docker image ls --format '{{.Size}}' "$IMAGE" | head -1)"

if [ -z "$human" ]; then
  echo "FAIL  $IMAGE: image not found" >&2
  exit 1
fi

size_mb="$(awk -v s="$human" 'BEGIN {
  num = s + 0
  unit = s
  sub(/^[0-9.]+/, "", unit)
  if (unit == "B")                    mult = 0.000001
  else if (unit == "kB" || unit == "KB") mult = 0.001
  else if (unit == "MB")              mult = 1
  else if (unit == "GB")              mult = 1000
  else if (unit == "TB")              mult = 1000000
  else { print "unparseable"; exit }
  printf "%.0f", num * mult
}')"

if [ "$size_mb" = "unparseable" ]; then
  echo "FAIL  $IMAGE: cannot parse size '$human'" >&2
  exit 1
fi

if [ "$size_mb" -gt "$MAX_MB" ]; then
  echo "FAIL  $IMAGE size ${human} (${size_mb}MB) exceeds budget ${MAX_MB}MB" >&2
  fail=1
else
  echo "OK    $IMAGE size ${human} (${size_mb}MB) within budget ${MAX_MB}MB"
fi

# --- dependency contract -------------------------------------------------
probe='
status=0
for b in "$@"; do
  path="$(command -v "$b" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    echo "  MISSING  $b"
    status=1
    continue
  fi
  if [ ! -x "$path" ]; then
    echo "  NOTEXEC  $b ($path)"
    status=1
    continue
  fi
  # Capture in full and trim afterwards. Piping straight into head(1) closes
  # the pipe early and SIGPIPEs the child, which makes mise abort noisily.
  if out="$("$b" --version 2>&1)"; then
    echo "  OK       $b  $path  $(printf %s "$out" | head -1)"
  else
    echo "  BROKEN   $b ($path) failed to execute: $(printf %s "$out" | head -1)"
    status=1
  fi
done
exit $status
'

echo "      $IMAGE dependency contract:"
if docker run --rm --entrypoint sh "$IMAGE" -c "$probe" probe "$@"; then
  echo "OK    $IMAGE provides $*"
else
  echo "FAIL  $IMAGE is missing or cannot execute a required dependency" >&2
  fail=1
fi

exit "$fail"
