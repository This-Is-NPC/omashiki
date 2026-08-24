#!/usr/bin/env bash
# Installs the repo's git hooks by pointing core.hooksPath at .githooks/.
#
# Using core.hooksPath instead of copying into .git/hooks means the hooks are
# versioned, reviewable, and update with a pull — a copied hook silently rots
# the moment someone edits the source.
#
#   .scripts/install-hooks.sh          install
#   .scripts/install-hooks.sh --off    revert to .git/hooks
#
# Bypass a single push with `git push --no-verify` when you deliberately need
# to skip local CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" = "--off" ]; then
  git config --unset core.hooksPath || true
  echo "hooks disabled; restored .git/hooks"
  exit 0
fi

chmod +x .githooks/* .scripts/arch_check.sh .scripts/ci.sh 2>/dev/null || true
git config core.hooksPath .githooks
echo "core.hooksPath = .githooks"
echo "pre-push active: full local CI (.scripts/ci.sh)"
echo "one-time bypass: git push --no-verify"
