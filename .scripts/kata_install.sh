#!/usr/bin/env bash
# Install the pinned Kata runtime-rs bundle and register it with Docker.
#
# This is deliberately host-only. It does not create or inspect a VM.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/vm/manifest.toml"
SUDO=(sudo -n)
TMP=""
CONFIG_REPLACED=0
DOCKER_RESTARTED=0
OLD_CONFIG_EXISTS=0
OLD_CONFIG_BACKUP=""

usage() {
  printf 'usage: %s [--manifest PATH]\n' "$(basename "$0")" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest=*) MANIFEST="${1#*=}"; shift ;;
    --manifest)
      [ "$#" -ge 2 ] || usage
      MANIFEST="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ -z "${SUDO_USER:-}" ]; then
  printf 'invoke this installer with explicit sudo: sudo %s\n' "$0" >&2
  exit 1
fi

for command in curl docker dockerd sha256sum python3 sudo systemctl tar zstd; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'required command is missing: %s\n' "$command" >&2
    exit 1
  }
done

[ -r "$MANIFEST" ] || {
  printf 'manifest is not readable: %s\n' "$MANIFEST" >&2
  exit 1
}

if ! "${SUDO[@]}" true 2>/dev/null; then
  printf 'passwordless sudo is required; run this installer with explicit sudo\n' >&2
  exit 1
fi

# Read the pin from the checked-in manifest rather than maintaining a second
# URL/checksum in this installer. The release identity and install paths are
# still constrained here so a malformed or retargeted manifest fails closed.
manifest_values="$(python3 - "$MANIFEST" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
try:
    with path.open("rb") as source:
        document = tomllib.load(source)
    kata = document["runtime"]["kata"]
    values = [
        kata["version"],
        kata["archive"],
        kata["url"],
        kata["sha256"],
        kata["install_root"],
        kata["runtime_path"],
        kata["hypervisor_path"],
        kata["daemon_config"],
        kata["config_path"],
    ]
except (KeyError, TypeError, tomllib.TOMLDecodeError, OSError) as error:
    raise SystemExit(f"invalid Kata manifest: {error}")

version, archive, url, sha256, install_root, runtime_path, hypervisor_path, daemon_config, config_path = values
if any(not isinstance(value, str) or not value.strip() for value in values):
    raise SystemExit("Kata manifest values must be non-empty strings")
expected_archive = f"kata-static-{version}-amd64.tar.zst"
expected_url = f"https://github.com/kata-containers/kata-containers/releases/download/{version}/{expected_archive}"
if version != "4.1.0":
    raise SystemExit(f"Kata version is not pinned to 4.1.0: {version!r}")
if archive != expected_archive or url != expected_url:
    raise SystemExit("Kata archive is not the pinned 4.1.0 amd64 release")
if not re.fullmatch(r"[0-9a-f]{64}", sha256):
    raise SystemExit("Kata archive sha256 must be 64 lowercase hexadecimal characters")
if install_root != "/opt/kata":
    raise SystemExit(f"unexpected Kata install root: {install_root!r}")
if runtime_path != f"{install_root}/runtime-rs/bin/containerd-shim-kata-v2":
    raise SystemExit("manifest runtime_path is not the Kata runtime-rs shim")
if hypervisor_path != f"{install_root}/bin/cloud-hypervisor":
    raise SystemExit("manifest hypervisor_path is not Cloud Hypervisor")
if daemon_config != "/etc/docker/daemon.json":
    raise SystemExit(f"unexpected Docker daemon config path: {daemon_config!r}")
expected_config = f"{install_root}/share/defaults/kata-containers/runtime-rs/configuration-clh-runtime-rs.toml"
if config_path != expected_config:
    raise SystemExit("manifest config_path is not the Cloud Hypervisor runtime-rs config")
for value in values:
    if "\x00" in value or "\n" in value or "\r" in value:
        raise SystemExit("Kata manifest values may not contain control characters")

print("\n".join(values))
PY
)"
mapfile -t manifest_lines <<< "$manifest_values"
[ "${#manifest_lines[@]}" -eq 9 ] || {
  printf 'failed to read all Kata manifest values\n' >&2
  exit 1
}

KATA_VERSION="${manifest_lines[0]}"
ARCHIVE_NAME="${manifest_lines[1]}"
ARCHIVE_URL="${manifest_lines[2]}"
ARCHIVE_SHA256="${manifest_lines[3]}"
INSTALL_ROOT="${manifest_lines[4]}"
RUNTIME_PATH="${manifest_lines[5]}"
HYPERVISOR_PATH="${manifest_lines[6]}"
DAEMON_CONFIG="${manifest_lines[7]}"
KATA_CONFIG="${manifest_lines[8]}"

if ! "${SUDO[@]}" test -c /dev/kvm || ! "${SUDO[@]}" test -r /dev/kvm || ! "${SUDO[@]}" test -w /dev/kvm; then
  printf '/dev/kvm must exist and be readable and writable for Kata\n' >&2
  exit 1
fi

if "${SUDO[@]}" test -L "$INSTALL_ROOT"; then
  printf 'refusing symlinked Kata install root: %s\n' "$INSTALL_ROOT" >&2
  exit 1
fi
if "${SUDO[@]}" test -e "$INSTALL_ROOT" && ! "${SUDO[@]}" test -d "$INSTALL_ROOT"; then
  printf 'Kata install root is not a directory: %s\n' "$INSTALL_ROOT" >&2
  exit 1
fi

installed_kata_ready() {
  local version_output
  "${SUDO[@]}" test -d "$INSTALL_ROOT" || return 1
  "${SUDO[@]}" test -x "$RUNTIME_PATH" || return 1
  "${SUDO[@]}" test -x "$HYPERVISOR_PATH" || return 1
  "${SUDO[@]}" test -f "$KATA_CONFIG" || return 1
  "${SUDO[@]}" python3 "$ROOT/.scripts/kata_runtime_config.py" \
    "$KATA_CONFIG" "$HYPERVISOR_PATH" || return 1
  version_output="$("${SUDO[@]}" "$RUNTIME_PATH" --version 2>/dev/null)" || return 1
  case "$version_output" in
    *"version: $KATA_VERSION,"*) return 0 ;;
    *) return 1 ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/omashiki-kata-install.XXXXXX")"
cleanup() {
  rm -rf -- "$TMP"
}
rollback_on_exit() {
  local status=$?
  if [ "$CONFIG_REPLACED" -eq 1 ] && [ "$DOCKER_RESTARTED" -eq 0 ]; then
    printf 'attempting Docker daemon config rollback\n' >&2
    if [ "$OLD_CONFIG_EXISTS" -eq 1 ]; then
      "${SUDO[@]}" cp -p -- "$OLD_CONFIG_BACKUP" "$DAEMON_CONFIG" || true
    else
      "${SUDO[@]}" rm -f -- "$DAEMON_CONFIG" || true
    fi
    "${SUDO[@]}" systemctl restart docker || \
      printf 'Docker restart after daemon config rollback failed\n' >&2
  fi
  cleanup
  exit "$status"
}
trap rollback_on_exit EXIT

ARCHIVE="$TMP/$ARCHIVE_NAME"
STAGE="$TMP/stage"
mkdir -m 700 "$STAGE"

if installed_kata_ready; then
  printf 'reusing validated Kata %s installation at %s\n' "$KATA_VERSION" "$INSTALL_ROOT"
else
  printf 'downloading Kata %s (the curl bar below is the activity indicator)\n' "$KATA_VERSION"
  curl --fail --location --show-error --progress-bar --retry 3 --output "$ARCHIVE" "$ARCHIVE_URL"
  printf 'verifying Kata archive checksum\n'
  actual_sha256="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
  [ "$actual_sha256" = "$ARCHIVE_SHA256" ] || {
    printf 'Kata archive checksum mismatch: expected %s, got %s\n' "$ARCHIVE_SHA256" "$actual_sha256" >&2
    exit 1
  }

  # The checksum authenticates the release, while this check prevents an archive
  # path traversal from escaping the temporary extraction directory.
  printf 'validating Kata archive paths\n'
  if ! zstd -dc -- "$ARCHIVE" | tar -tf - | python3 "$ROOT/.scripts/kata_archive_paths.py"; then
    printf 'Kata archive path validation failed\n' >&2
    exit 1
  fi

  printf 'extracting Kata archive\n'
  zstd -dc -- "$ARCHIVE" | tar --no-same-owner --no-same-permissions -xf - -C "$STAGE"
  STAGED_ROOT="$STAGE/opt/kata"
  [ -d "$STAGED_ROOT" ] && [ ! -L "$STAGED_ROOT" ] || {
    printf 'Kata archive has no safe opt/kata root\n' >&2
    exit 1
  }

  for staged_path in "$STAGED_ROOT/runtime-rs/bin/containerd-shim-kata-v2" \
                    "$STAGED_ROOT/bin/cloud-hypervisor" \
                    "$STAGED_ROOT/share/defaults/kata-containers/runtime-rs/configuration-clh-runtime-rs.toml"; do
    [ ! -L "$staged_path" ] || {
      printf 'refusing symlinked Kata path: %s\n' "$staged_path" >&2
      exit 1
    }
  done
  [ -x "$STAGED_ROOT/runtime-rs/bin/containerd-shim-kata-v2" ] || { printf 'Kata runtime shim is missing or not executable\n' >&2; exit 1; }
  [ -x "$STAGED_ROOT/bin/cloud-hypervisor" ] || { printf 'Cloud Hypervisor is missing or not executable\n' >&2; exit 1; }
  [ -f "$STAGED_ROOT/share/defaults/kata-containers/runtime-rs/configuration-clh-runtime-rs.toml" ] || { printf 'Kata runtime-rs config is missing\n' >&2; exit 1; }
  python3 "$ROOT/.scripts/kata_runtime_config.py" \
    "$STAGED_ROOT/share/defaults/kata-containers/runtime-rs/configuration-clh-runtime-rs.toml" \
    "$HYPERVISOR_PATH"

  "${SUDO[@]}" install -d -m 0755 -- "$INSTALL_ROOT"
  printf 'installing Kata under %s\n' "$INSTALL_ROOT"
  "${SUDO[@]}" cp -a --no-preserve=ownership -- "$STAGED_ROOT"/. "$INSTALL_ROOT"/

  installed_kata_ready || {
    printf 'installed Kata files failed runtime and configuration validation\n' >&2
    exit 1
  }
fi

if "${SUDO[@]}" test -L "$(dirname "$DAEMON_CONFIG")"; then
  printf 'refusing symlinked Docker config directory\n' >&2
  exit 1
fi
"${SUDO[@]}" install -d -m 0755 -- "$(dirname "$DAEMON_CONFIG")"
CANDIDATE="$TMP/daemon.json"
merge_result="$("${SUDO[@]}" python3 - "$DAEMON_CONFIG" "$CANDIDATE" "$RUNTIME_PATH" "$KATA_CONFIG" <<'PY'
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

source, candidate, runtime_path, config_path = map(Path, sys.argv[1:])
if source.is_symlink():
    raise SystemExit(f"refusing symlinked Docker daemon config: {source}")
if source.exists() and not source.is_file():
    raise SystemExit(f"Docker daemon config is not a regular file: {source}")
try:
    data = json.loads(source.read_text()) if source.exists() else {}
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid Docker daemon config: {error}")
if not isinstance(data, dict):
    raise SystemExit("Docker daemon config must be a JSON object")
runtimes = data.get("runtimes", {})
if not isinstance(runtimes, dict):
    raise SystemExit("Docker daemon runtimes must be a JSON object")
expected = {"runtimeType": str(runtime_path), "options": {"ConfigPath": str(config_path)}}
existing = runtimes.get("kata")
if existing is not None and existing != expected:
    raise SystemExit("Docker runtime 'kata' is already registered with different settings")
runtimes["kata"] = expected
data["runtimes"] = runtimes

mode = stat.S_IMODE(source.stat().st_mode) if source.exists() else 0o644
candidate_path = Path(candidate)
candidate_path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".daemon-candidate-", dir=candidate_path.parent)
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w") as output:
        json.dump(data, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, candidate_path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("1" if existing != expected or not source.exists() else "0")
PY
)"

if [ "$merge_result" = "1" ]; then
  printf 'validating updated Docker daemon configuration\n'
  "${SUDO[@]}" dockerd --validate --config-file="$CANDIDATE"
else
  printf 'validating existing Docker daemon configuration\n'
  "${SUDO[@]}" dockerd --validate --config-file="$DAEMON_CONFIG"
fi

if [ "$merge_result" = "1" ]; then
  OLD_CONFIG_BACKUP="$TMP/daemon.json.old"
  if "${SUDO[@]}" test -e "$DAEMON_CONFIG"; then
    OLD_CONFIG_EXISTS=1
    "${SUDO[@]}" cp -p -- "$DAEMON_CONFIG" "$OLD_CONFIG_BACKUP"
  fi
  "${SUDO[@]}" python3 - "$CANDIDATE" "$DAEMON_CONFIG" <<'PY'
import os
import stat
import sys
import tempfile
from pathlib import Path

candidate, destination = map(Path, sys.argv[1:])
if destination.is_symlink():
    raise SystemExit(f"refusing symlinked Docker daemon config: {destination}")
parent = destination.parent
parent.mkdir(mode=0o755, exist_ok=True)
mode = stat.S_IMODE(destination.stat().st_mode) if destination.exists() else 0o644
fd, temporary = tempfile.mkstemp(prefix=".omashiki-daemon-", dir=parent)
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "wb") as output, candidate.open("rb") as source:
        output.write(source.read())
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, destination)
    directory_fd = os.open(parent, os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
  CONFIG_REPLACED=1
fi

docker_has_kata() {
  local runtimes
  runtimes="$("${SUDO[@]}" docker info --format '{{json .Runtimes}}')" || return 1
  python3 - "$runtimes" <<'PY'
import json
import sys

try:
    runtimes = json.loads(sys.argv[1])
except (IndexError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(runtimes, dict) and "kata" in runtimes else 1)
PY
}

needs_restart=0
[ "$merge_result" = "1" ] && needs_restart=1
if ! docker_has_kata; then
  needs_restart=1
fi

restore_daemon_config() {
  if [ "$OLD_CONFIG_EXISTS" -eq 1 ]; then
    "${SUDO[@]}" cp -p -- "$OLD_CONFIG_BACKUP" "$DAEMON_CONFIG"
  else
    "${SUDO[@]}" rm -f -- "$DAEMON_CONFIG"
  fi
  "${SUDO[@]}" systemctl restart docker
  CONFIG_REPLACED=0
}

if [ "$needs_restart" -eq 1 ]; then
  printf 'restarting Docker to activate runtime kata\n'
  "${SUDO[@]}" systemctl restart docker
  DOCKER_RESTARTED=1
  if ! docker_has_kata; then
    printf 'Docker restarted but does not advertise runtime kata\n' >&2
    if [ "$CONFIG_REPLACED" -eq 1 ]; then
      printf 'restoring the previous Docker daemon config\n' >&2
      restore_daemon_config || printf 'Docker daemon config rollback failed\n' >&2
    fi
    exit 1
  fi
fi

printf 'Kata %s installed; Docker runtime kata is advertised\n' "$KATA_VERSION"
