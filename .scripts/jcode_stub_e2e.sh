#!/usr/bin/env bash
# Run the standard runc/jcode E2E against the deterministic local LLM stub.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for command in flock mise python3; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'required command is missing: %s\n' "$command" >&2
    exit 1
  }
done

umask 077
if [ -L .omashiki ] || { [ -e .omashiki ] && [ ! -d .omashiki ]; }; then
  printf 'refusing unsafe .omashiki lock directory\n' >&2
  exit 1
fi
mkdir -p .omashiki
exec 9>.omashiki/e2e.lock
if ! flock -n 9; then
  printf 'another overture E2E is already running\n' >&2
  exit 1
fi
export OMASHIKI_E2E_LOCK_HELD=1

mise run e2e:prepare:runc:jcode-stub
mise run agent:jcode:build

STUB_LOG="$ROOT/.omashiki/fake-llm-e2e.log"
STUB_PID=""
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT INT TERM

  if [ -n "$STUB_PID" ] && kill -0 "$STUB_PID" 2>/dev/null; then
    kill "$STUB_PID" 2>/dev/null || cleanup_status=1
    wait "$STUB_PID" 2>/dev/null || true
  fi
  if [ -n "$STUB_PID" ] && kill -0 "$STUB_PID" 2>/dev/null; then
    printf 'fake LLM process did not stop: pid=%s\n' "$STUB_PID" >&2
    cleanup_status=1
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    exit 1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 .scripts/loadtest/fake_llm.py \
  --host 127.0.0.1 \
  --port 8787 \
  --model fake-model \
  --scenario python-hello \
  --lat-ms 0 \
  --jitter-pct 0 \
  >"$STUB_LOG" 2>&1 &
STUB_PID=$!

ready=0
for ((attempt = 1; attempt <= 100; attempt++)); do
  if ! kill -0 "$STUB_PID" 2>/dev/null; then
    printf 'fake LLM exited before readiness; log follows:\n' >&2
    command cat "$STUB_LOG" >&2
    exit 1
  fi
  if python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8787/healthz", timeout=0.2).read()' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || {
  printf 'fake LLM did not become ready; log follows:\n' >&2
  command cat "$STUB_LOG" >&2
  exit 1
}

cd server
OMASHIKI_REAL_PROVIDER_E2E=1 \
OMASHIKI_AGENT_NETWORK_MODE=host \
MIX_ENV=test \
mix test test/integration/queue_real_provider_e2e_test.exs \
  --include real_jcode --exclude real_opencode --exclude real_claude
