#!/usr/bin/env bash
# Agent image gate: can this image actually satisfy a `mise install --yes`?
#
#   .scripts/agent_toolchain_check.sh IMAGE
#
# agent_image_check.sh asserts that the mise *binary* runs. That is not the
# same assertion. omashiki.toml declares
#
#   pre_steps = [{ argv = ["mise", "install", "--yes"] }]
#
# for [environments.opencode] and [environments.codex], and mise ships no
# precompiled erlang: its core plugin shells out to kerl, which compiles OTP
# from source. On a base without a C toolchain `mise --version` prints a
# version and `mise install` then dies at otp_src_27.2/erts/configure. That
# combination builds green, passes the size budget, passes the dependency
# contract, and fails at runtime — which is the regression this file exists to
# catch.
#
# The fixture pins erlang alone. The repo's own mise.toml also pins elixir,
# python and rebar, but those add ~50s and discriminate nothing: measured on
# debian:13-slim, python resolves to a python-build-standalone tarball and
# rebar to a release escript, so both install fine with no compiler present.
# erlang is the only entry in it that needs one.
#
# Installing is still not enough to call the capability restored. With gcc,
# make, libc6-dev and libncurses-dev but no g++ or libssl-dev, OTP's configure
# exits 0 and quietly reports
#
#   crypto : No usable OpenSSL found
#   ssl    : No usable OpenSSL found
#
# so `mise install --yes` succeeds and produces an erlang that cannot run mix,
# hex or TLS. The post-install assertion below runs crypto and ssl out of the
# installed tree for exactly that reason: a green install is not a green
# toolchain.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") IMAGE" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

IMAGE="$1"
ERLANG_VERSION="${OMASHIKI_TOOLCHAIN_FIXTURE_ERLANG:-27.2}"

FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "${FIXTURE}"; }
trap cleanup EXIT

cat >"${FIXTURE}/mise.toml" <<EOF
[tools]
erlang = "${ERLANG_VERSION}"
EOF
chmod 0755 "${FIXTURE}"
chmod 0644 "${FIXTURE}/mise.toml"

# Runs as uid 1000, the uid the orchestrator runs containers as, so a
# root-only writable path cannot make this pass where a real job would fail.
# MISE_DATA_DIR stays inside the container: a warm host cache would turn
# `mise install` into a no-op and the gate would stop discriminating.
probe='
set -e
mise install --yes
mise exec -- erl -noshell -eval '"'"'
  {ok, _} = application:ensure_all_started(crypto),
  {ok, _} = application:ensure_all_started(ssl),
  <<_:32/binary>> = crypto:hash(sha256, <<"omashiki">>),
  io:format("erlang ~s crypto+ssl ok~n", [erlang:system_info(otp_release)]),
  halt(0)
'"'"'
'

echo "      ${IMAGE} toolchain capability: mise install --yes (erlang ${ERLANG_VERSION})"

started="$(date +%s)"

if docker run --rm \
  --user 1000:1000 \
  --workdir /fixture \
  --entrypoint sh \
  -v "${FIXTURE}:/fixture:ro" \
  -e HOME=/tmp/agent-home \
  -e MISE_DATA_DIR=/tmp/mise/data \
  -e MISE_CACHE_DIR=/tmp/mise/cache \
  -e MISE_CONFIG_DIR=/tmp/mise/config \
  -e MISE_TRUSTED_CONFIG_PATHS=/fixture \
  -e MAKEFLAGS="-j$(nproc)" \
  "${IMAGE}" -c "${probe}"
then
  echo "OK    ${IMAGE} builds erlang ${ERLANG_VERSION} from source ($(($(date +%s) - started))s)"
  exit 0
else
  echo "FAIL  ${IMAGE} cannot satisfy 'mise install --yes' for a compiled toolchain ($(($(date +%s) - started))s)" >&2
  echo "      the mise binary runs; the toolchain it needs to build erlang does not." >&2
  exit 1
fi
