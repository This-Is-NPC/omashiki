#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mise run arch:check
mise run ci:server:vuln
mise run ci:server:fast
mise run ci:server:integration
mise run ci:server:assets
mise run ci:docker:server
mise run ci:docker:agent
mise run ci:docker:claude
