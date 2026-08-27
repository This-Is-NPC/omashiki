#!/usr/bin/env bash
# Architectural consistency gate.
#
#   .scripts/arch_check.sh            full  — all 13 invariants
#   .scripts/arch_check.sh --fast     the 11 static invariants only; INV5/INV7
#                                     are skipped and reported as skipped
#   .scripts/arch_check.sh --strict   ignore .scripts/arch-exceptions.txt and
#                                     show every violation, declared or not
#
# Eleven invariants are decidable from source text, so they are greps and run
# standalone in milliseconds. Two are not. INV5 must enumerate every behaviour
# actually compiled into the app and read its typespecs rather than its file
# text; INV7 must classify container rows and read the boot call graph. Those
# two live in server/test/omashiki/architecture_test.exs and the full run
# executes them.
#
# No path through this script prints PASS for a check it did not run. If the
# reflection suite is missing, that is a failure — two invariants would be
# unenforced — not a "not applicable".
#
# Known violations are listed in .scripts/arch-exceptions.txt with a reason
# and an owner item. An exception is a tracked debt, not a silenced check —
# the gate reports how many are active on every run.
#
# What this gate cannot do: prove a runtime boundary. It reads source, so it
# proves "no code path in this repo does X". An agent inside a container with
# network access can still reach a provider directly; that is closed by
# NetworkMode, not by grep. See .temp/plano-followups.md FU-1.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/server"
EXCEPTIONS="$ROOT/.scripts/arch-exceptions.txt"
FAST=0
STRICT=0
for a in "$@"; do
  case "$a" in
    --fast)   FAST=1 ;;
    --strict) STRICT=1 ;;
  esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; DIM=""; RST=""; }

failures=0
excepted=0

# excepted? <check-id> <path> -- --strict disables all exceptions
excepted?() {
  [ "$STRICT" -eq 1 ] && return 1
  [ -f "$EXCEPTIONS" ] || return 1
  grep -v '^[[:space:]]*#' "$EXCEPTIONS" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | awk -F'|' -v c="$1" -v p="$2" '$1==c && $2==p {found=1} END {exit !found}'
}

# report <check-id> <title> <hits...>   (hits on stdin as "path:line:text")
report() {
  local id="$1" title="$2" hits="$3" real=0

  if [ -z "$hits" ]; then
    printf '%s  PASS%s  %s\n' "$GRN" "$RST" "$title"
    return
  fi

  local out=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local path="${line%%:*}"
    if excepted? "$id" "$path"; then
      excepted=$((excepted + 1))
    else
      real=$((real + 1))
      out+="        $line"$'\n'
    fi
  done <<< "$hits"

  if [ "$real" -eq 0 ]; then
    printf '%s  PASS%s  %s %s(active exceptions)%s\n' "$GRN" "$RST" "$title" "$DIM" "$RST"
  else
    printf '%s  FAIL%s  %s\n' "$RED" "$RST" "$title"
    printf '%s' "$out"
    failures=$((failures + 1))
  fi
}

# scan <check-id> <title> <pattern> <search-path...> ; excludes via $EXCLUDE
scan() {
  local id="$1" title="$2" pattern="$3"; shift 3
  local hits
  hits="$(cd "$SRV" && grep -rnE "$pattern" "$@" 2>/dev/null | grep -vE "${EXCLUDE:-\$^}" || true)"
  report "$id" "$title" "$hits"
}

echo "Architecture consistency -- $ROOT"
[ "$STRICT" -eq 1 ] && printf '%s--strict: exceptions ignored, showing all violations%s\n' "$YEL" "$RST"
echo

# ---------------------------------------------------------------- INV1
# LLM output is mediated by provider adapters or the restricted harness CONNECT.
# SupplyChain.Proxy remains a separate boundary used only for registries.
EXCLUDE='^lib/omashiki/gateway/providers/|^lib/omashiki/llm_egress/proxy\.ex:|^lib/omashiki/supply_chain/proxy\.ex:'
scan LLM_EGRESS \
  "INV1  LLM output only through adapters/restricted proxy" \
  'Mint\.HTTP\.connect\(:https|api\.anthropic\.com|api\.openai\.com' \
  lib

# ---------------------------------------------------------------- INV2
# MCP forwarding only through Tools.Proxy; the controller delegates HTTP.
EXCLUDE='^lib/omashiki/tools/'
scan TOOL_EGRESS \
  "INV2  MCP forwarding only through Tools.Proxy" \
  'Mint\.HTTP\.(connect|request)' \
  lib/omashiki_web/controllers/api/tools_proxy_controller.ex lib/omashiki_web/mcp

# ---------------------------------------------------------------- INV3
# Instrumentation comes from the orchestrator, never an adapter. The concrete
# transport client is still inside the harness adapter boundary.
EXCLUDE='\$^'
scan ADAPTER_EVENTS \
  "INV3  adapters do not emit events/ledger" \
  'Events\.record|UsageLedger\.' \
  lib/omashiki/engine lib/omashiki/gateway/providers lib/omashiki/harness

# ---------------------------------------------------------------- INV4
# Harness turns only through the configured Adapter. Concrete HTTP transport
# lives in Plugin.Http; legacy harness modules may remain until 2829 but must
# not call the removed OpenCode.Http module.
EXCLUDE='^lib/omashiki/harness/(open_code(_http)?|claude_code)\.ex|^lib/omashiki/plugin/http\.ex'
scan ENGINE_DIRECT \
  "INV4  adapter turns use the configured contract" \
  'OpenCode\.Http' \
  lib

# ---------------------------------------------------------------- INV13
# Adapters receive runtime capabilities, never the Docker implementation.
EXCLUDE='\$^'
scan ADAPTER_RUNTIME \
  "INV13 adapters do not depend on ContainerManager" \
  'ContainerManager' \
  lib/omashiki/harness

# ---------------------------------------------------------------- INV6
# Port contracts cannot name a vendor, including at the runtime boundary.
EXCLUDE='\$^'
scan PORT_VENDOR \
  "INV6  port contracts use no vendor vocabulary" \
  '[Dd]ocker|opencode' \
  lib/omashiki/runtime/container_manager_behaviour.ex

# ---------------------------------------------------------------- INV8
# engine/ describes what runs; runtime describes where. Do not conflate them.
EXCLUDE='\$^'
scan ENGINE_RUNTIME \
  "INV8  engine/ has no runtime concept" \
  '[Dd]ocker|container_id|ContainerManager|:image\b|field :image' \
  lib/omashiki/engine

# ---------------------------------------------------------------- INV9
# `transport` used to conflate the harness protocol with the runtime kind. It
# must not return as an engine field.
EXCLUDE='transport_opts|Streamable HTTP|transport: "Streamable'
scan CONFLATED_TRANSPORT \
  "INV9  no conflated transport field in engine" \
  'field :transport|profile\.transport|:transport\b' \
  lib/omashiki/engine lib/omashiki/orchestrator lib/omashiki_web/live

# ---------------------------------------------------------------- INV10
# The orchestrator does not branch on profile identity. The provisioned fact is
# authoritative, not a vendor name.
EXCLUDE='\$^'
scan PROFILE_KEY_BRANCH \
  "INV10  orchestrator does not branch on profile key" \
  '"opencode"' \
  lib/omashiki/orchestrator lib/omashiki/gateway lib/omashiki/tools

# ---------------------------------------------------------------- INV11
# Delivering files into the sandbox belongs to the runtime. engine/ does not
# know about $HOME.
EXCLUDE='\$^'
scan ENGINE_DELIVERY \
  "INV11  engine/ does not describe sandbox delivery" \
  '\$HOME|config_artifacts' \
  lib/omashiki/engine

# ---------------------------------------------------------------- INV12
# Runtime port vocabulary is neutral.
EXCLUDE='\$^'
scan PORT_RUNTIME_ID \
  "INV12  runtime port uses a neutral id" \
  'container_id' \
  lib/omashiki/runtime/container_manager_behaviour.ex

echo
if [ "$excepted" -gt 0 ]; then
  printf '%s  %d violation(s) covered by .scripts/arch-exceptions.txt%s\n' \
    "$YEL" "$excepted" "$RST"
fi

# ---------------------------------------------------------------- ExUnit
# INV5 and INV7 are the two invariants a grep cannot decide. They are ExUnit
# because they need the compiled application, not because they are optional.
REFLECTION_SUITE="test/omashiki/architecture_test.exs"

if [ "$FAST" -eq 0 ]; then
  enforced=13
  echo
  DB_PORT="${OMASHIKI_DB_PORT:-5442}"
  echo "Reflection checks (ExUnit) -- INV5 vocabulary, INV7 orphan behaviour"
  printf '%s  test database at localhost:%s (OMASHIKI_DB_PORT)%s\n' "$DIM" "$DB_PORT" "$RST"

  if [ -f "$SRV/$REFLECTION_SUITE" ]; then
    reflection_out="$(cd "$SRV" && OMASHIKI_DB_PORT="$DB_PORT" MIX_ENV=test \
      mix test "$REFLECTION_SUITE" --color 2>&1)"
    reflection_status=$?

    if [ "$reflection_status" -eq 0 ]; then
      printf '%s\n' "$reflection_out" | tail -3
      printf '%s  PASS%s  INV5  port contracts use no vendor vocabulary\n' "$GRN" "$RST"
      printf '%s  PASS%s  INV7  orphan reclamation is a property of the runtime port\n' \
        "$GRN" "$RST"
    else
      # Print everything, not tail -5: the whole point is to name the invariant
      # that broke.
      printf '%s\n' "$reflection_out"
      failures=$((failures + 1))
      printf '%s  FAIL%s  INV5/INV7 reflection suite failed (exit %d)\n' \
        "$RED" "$RST" "$reflection_status"
      printf '%s  for database errors, set OMASHIKI_DB_PORT to your PostgreSQL port%s\n' \
        "$YEL" "${RST}"
    fi
  else
    # Absent suite = two unenforced invariants. Count both, and do not let the
    # summary keep claiming 13.
    failures=$((failures + 2))
    enforced=11
    printf '%s  FAIL%s  INV5/INV7 reflection suite missing: %s\n' \
      "$RED" "$RST" "$SRV/$REFLECTION_SUITE"
    printf '        INV5 and INV7 cannot be decided by grep, so this gate now enforces\n'
    printf '        11 of the 13 invariants it names. Restore the suite, or delete the\n'
    printf '        INV5/INV7 headings and lower the advertised count to match.\n'
  fi
else
  enforced=11
  printf '%s  --fast: INV5 and INV7 NOT checked here -- they need the compiled\n' "$YEL"
  printf '  application. Run without --fast to enforce them.%s\n' "$RST"
fi

echo
if [ "$failures" -gt 0 ]; then
  printf '%s%d check(s) failed.%s %s(%d of 13 invariants enforced on this run)%s\n' \
    "$RED" "$failures" "$RST" "$DIM" "$enforced" "$RST"
  echo "Fix the violations or declare a justified exception in .scripts/arch-exceptions.txt"
  exit 1
fi
printf '%sArchitecture consistent.%s %s(%d of 13 invariants enforced on this run)%s\n' \
  "$GRN" "$RST" "$DIM" "$enforced" "$RST"
