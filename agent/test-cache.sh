#!/usr/bin/env bash
set -euo pipefail

IMAGE="${AGENT_IMAGE:-omashiki/agent:latest}"
ROOT="$(mktemp -d "${HOME}/.cache/omashiki-smoke.XXXXXX")"
PROJECT="${ROOT}/project"
CACHE="${ROOT}/cache"

cleanup() {
  chmod -R u+w "${ROOT}" 2>/dev/null || true
  rm -rf "${ROOT}"
}
trap cleanup EXIT

mkdir -p "${PROJECT}" "${CACHE}"
cat >"${PROJECT}/mise.toml" <<'EOF'
[tools]
node = "24.6.0"
go = "1.24.6"
EOF
cat >"${PROJECT}/package.json" <<'EOF'
{"private":true,"dependencies":{"is-number":"7.0.0"}}
EOF
cat >"${PROJECT}/Cargo.toml" <<'EOF'
[package]
name = "omashiki-cache-smoke"
version = "0.1.0"
edition = "2024"

[dependencies]
itoa = "1.0.15"
EOF
mkdir -p "${PROJECT}/src"
printf '%s\n' 'pub fn smoke() -> String { itoa::Buffer::new().format(42).to_owned() }' \
  >"${PROJECT}/src/lib.rs"
cat >"${PROJECT}/go.mod" <<'EOF'
module example.com/omashiki/cache-smoke

go 1.24

require rsc.io/quote v1.5.2
EOF

run_install() {
  local project="$1"
  local network="$2"
  local npm_mode="$3"
  local network_args=()
  local go_proxy="https://proxy.golang.org"

  if [[ "${network}" == "offline" ]]; then
    network_args=(--network none)
    go_proxy="off"
  fi

  docker run --rm \
    --entrypoint bash \
    --user "$(stat -c '%u:%g' "${project}")" \
    --workdir "${project}" \
    --read-only \
    --tmpfs "/tmp:rw,noexec,nosuid,size=512m,uid=$(stat -c '%u' "${project}"),gid=$(stat -c '%g' "${project}")" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    "${network_args[@]}" \
    -v "${project}:${project}" \
    -v "${CACHE}:/omashiki-cache/global" \
    -e HOME=/tmp/agent-home \
    -e MISE_DATA_DIR=/omashiki-cache/global/mise/data \
    -e MISE_CACHE_DIR=/omashiki-cache/global/mise/cache \
    -e XDG_CACHE_HOME=/omashiki-cache/global/xdg \
    -e npm_config_cache=/omashiki-cache/global/npm \
    -e CARGO_HOME=/omashiki-cache/global/cargo \
    -e GOPATH=/omashiki-cache/global/go \
    -e GOMODCACHE=/omashiki-cache/global/go/pkg/mod \
    "${IMAGE}" \
    -lc "mise install --yes && mise exec -- npm install ${npm_mode} && cargo fetch ${npm_mode} && GOPROXY=${go_proxy} mise exec -- go mod download"
}

# Cold run populates the toolchain and package-manager caches.
run_install "${PROJECT}" online ""
rm -rf "${PROJECT}/node_modules"

# A fresh dependency tree must be reconstructable with networking disabled.
run_install "${PROJECT}" offline "--offline"
test -f "${PROJECT}/node_modules/is-number/index.js"
test -f "${PROJECT}/Cargo.lock"
test -f "${PROJECT}/go.sum"

# Two fresh worktrees consume the same cache concurrently.
cp -a "${PROJECT}" "${ROOT}/project-a"
cp -a "${PROJECT}" "${ROOT}/project-b"
rm -rf "${ROOT}/project-a/node_modules" "${ROOT}/project-b/node_modules"

run_install "${ROOT}/project-a" offline "--offline" &
pid_a=$!
run_install "${ROOT}/project-b" offline "--offline" &
pid_b=$!
wait "${pid_a}"
wait "${pid_b}"

test -f "${ROOT}/project-a/node_modules/is-number/index.js"
test -f "${ROOT}/project-b/node_modules/is-number/index.js"

for secret_path in \
  "${CACHE}/auth.json" \
  "${CACHE}/.npmrc" \
  "${CACHE}/cargo/credentials" \
  "${CACHE}/cargo/credentials.toml" \
  "${CACHE}/opencode/auth.json"; do
  if [[ -e "${secret_path}" ]]; then
    echo "credential file found in cache: ${secret_path}" >&2
    exit 1
  fi
done

echo "Agent cache smoke test passed"
