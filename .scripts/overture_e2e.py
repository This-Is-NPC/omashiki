#!/usr/bin/env python3
"""Create the disposable nested repository and stage local E2E credentials."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OVERTURE = ROOT / "overture"
WORKTREE_ROOT = OVERTURE / ".omashiki-worktrees"
SNAPSHOT_ROOT = ROOT / ".omashiki" / "e2e"
E2E_CONFIG = ROOT / "omashiki.e2e.toml"
LOCK_PATH = ROOT / ".omashiki" / "e2e.lock"
OPENCODE_CONFIG = Path.home() / ".config" / "opencode" / "opencode.json"
OPENCODE_AUTH = Path.home() / ".local" / "share" / "opencode" / "auth.json"
CLAUDE_CREDENTIALS = Path.home() / ".claude" / ".credentials.json"
LOCAL_LLM_BASE_URL_VAR = "OMASHIKI_LOCAL_LLM_BASE_URL"
LOCAL_LLM_MODEL = "qwen/qwen3.5-9b"


def run(*argv: str, cwd: Path | None = None, capture: bool = False) -> str:
    result = subprocess.run(
        argv,
        cwd=cwd,
        check=True,
        text=True,
        capture_output=capture,
    )
    return result.stdout.strip() if capture else ""


def assert_safe_existing_repo() -> None:
    if OVERTURE.is_symlink():
        raise SystemExit(f"refusing to wipe symlink: {OVERTURE}")
    if not OVERTURE.is_dir():
        raise SystemExit(f"refusing to wipe non-directory: {OVERTURE}")
    if not (OVERTURE / ".git").exists():
        raise SystemExit(
            "refusing to wipe a directory that is not the overture Git repo: "
            f"{OVERTURE}"
        )

    top = Path(run("git", "rev-parse", "--show-toplevel", cwd=OVERTURE, capture=True)).resolve()
    if top != OVERTURE:
        raise SystemExit(f"refusing to wipe unexpected Git root: {top}")

    allowed = (OVERTURE, WORKTREE_ROOT)
    lines = run("git", "worktree", "list", "--porcelain", cwd=OVERTURE, capture=True).splitlines()
    for line in lines:
        if not line.startswith("worktree "):
            continue
        path = Path(line.removeprefix("worktree ")).resolve()
        if path == allowed[0] or path.is_relative_to(allowed[1]):
            continue
        raise SystemExit(f"refusing to wipe repo with external worktree: {path}")


@contextmanager
def fixture_lock():
    if LOCK_PATH.parent.is_symlink():
        raise SystemExit(f"refusing to use a symlink lock path: {LOCK_PATH.parent}")
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with LOCK_PATH.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def wipe() -> None:
    with fixture_lock():
        wipe_locked()


def wipe_locked() -> None:
    if OVERTURE.exists() or OVERTURE.is_symlink():
        assert_safe_existing_repo()
        shutil.rmtree(OVERTURE)

    OVERTURE.mkdir()
    run("git", "init", "-q", "-b", "main", cwd=OVERTURE)
    run("git", "config", "user.name", "Overture E2E", cwd=OVERTURE)
    run("git", "config", "user.email", "e2e@omashiki.local", cwd=OVERTURE)
    (OVERTURE / ".gitignore").write_text("/.omashiki-worktrees/\n", encoding="utf-8")
    (OVERTURE / "README.md").write_text("# Overture\n\nDisposable Omashiki E2E fixture.\n", encoding="utf-8")
    run("git", "add", ".gitignore", "README.md", cwd=OVERTURE)
    run("git", "commit", "-q", "-m", "chore: initialize overture fixture", cwd=OVERTURE)
    print(f"ready: {OVERTURE} (main)")


def copy_private_file(source: Path, destination: Path, provider: str) -> None:
    if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
        raise SystemExit(f"required {provider} snapshot is missing or empty: {source}")
    if SNAPSHOT_ROOT.is_symlink() or destination.is_symlink():
        raise SystemExit(f"refusing unsafe {provider} snapshot destination: {destination}")
    SNAPSHOT_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(SNAPSHOT_ROOT, 0o700)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o600)


def ensure_private_snapshot(source: Path, destination: Path, provider: str) -> None:
    if destination.is_symlink():
        raise SystemExit(f"refusing unsafe {provider} snapshot destination: {destination}")
    if destination.is_file() and destination.stat().st_size > 0:
        os.chmod(destination, 0o600)
        return
    copy_private_file(source, destination, provider)


def _toml_str(value: str) -> str:
    return json.dumps(value)


def _environment_stanza(
    *,
    name: str,
    preset: str,
    image: str,
    credentials: list[str],
    caches: list[str],
    cpus: float,
    memory: str,
    pids: int,
) -> str:
    creds = ", ".join(_toml_str(item) for item in credentials)
    cache_items = ", ".join(_toml_str(item) for item in caches)
    return f"""
[environments.{name}]
preset = {_toml_str(preset)}
isolation = "docker"
image = {_toml_str(image)}
sink = "git"
packages = []
executables = ["git"]
credentials = [{creds}]
caches = [{cache_items}]
timeout_ms = 900000
network = "restricted"
mounts = []
pre_steps = []
post_steps = []

[environments.{name}.policy]
mode = "off"

[environments.{name}.resources]
cpus = {cpus}
memory = {_toml_str(memory)}
pids = {pids}
"""


def prepare(provider: str) -> None:
    with fixture_lock():
        prepare_locked(provider)


def prepare_locked(provider: str) -> None:
    if provider not in ("all", "opencode", "claude", "jcode"):
        raise SystemExit(f"unknown provider preparation target: {provider}")

    assert_safe_existing_repo()
    run("docker", "info", capture=True)
    SNAPSHOT_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(SNAPSHOT_ROOT, 0o700)
    opencode_ready = False
    claude_ready = False
    jcode_ready = False

    if provider in ("all", "opencode"):
        copy_private_file(OPENCODE_CONFIG, SNAPSHOT_ROOT / "opencode.json", "OpenCode config")
        copy_private_file(OPENCODE_AUTH, SNAPSHOT_ROOT / "auth.json", "OpenCode auth")
        opencode_ready = True

    if provider in ("all", "claude"):
        ensure_private_snapshot(
            CLAUDE_CREDENTIALS,
            SNAPSHOT_ROOT / "claude-credentials.json",
            "Claude Code credentials",
        )
        claude_ready = True

    # jcode stages no host credential: it has no host-auth route and reaches the
    # model only through the gateway, which resolves the local server's address
    # from the environment. Fail here rather than at Config.load! in the test.
    if provider in ("all", "jcode"):
        if not os.environ.get(LOCAL_LLM_BASE_URL_VAR):
            raise SystemExit(
                f"{LOCAL_LLM_BASE_URL_VAR} is unset; jcode needs the local model server, "
                f"for example {LOCAL_LLM_BASE_URL_VAR}=http://<host>:8080/v1"
            )
        jcode_ready = True

    base = (ROOT / "omashiki.toml").read_text(encoding="utf-8").rstrip()
    additions = """

[repositories.overture]
path = "overture"
base_branch = "main"
"""
    if opencode_ready:
        auth = SNAPSHOT_ROOT / "auth.json"
        config = SNAPSHOT_ROOT / "opencode.json"
        additions += f"""
[host_credentials.e2e-opencode]
kind = "opencode"
auth = {_toml_str(str(auth))}
config = {_toml_str(str(config))}
"""
        additions += _environment_stanza(
            name="e2e-opencode",
            preset="opencode",
            image="omashiki/agent:latest",
            credentials=["e2e-opencode"],
            caches=["global"],
            cpus=2.0,
            memory="2GB",
            pids=256,
        )
    if claude_ready:
        credentials = SNAPSHOT_ROOT / "claude-credentials.json"
        additions += f"""
[host_credentials.e2e-claude]
kind = "claude-code"
credentials = {_toml_str(str(credentials))}
"""
        additions += _environment_stanza(
            name="e2e-claude",
            preset="claude-code",
            image="omashiki/agent-claude:latest",
            credentials=["e2e-claude"],
            caches=["global"],
            cpus=2.0,
            memory="2GB",
            pids=256,
        )
    if jcode_ready:
        # Tracked omashiki.toml keeps these commented so a missing
        # OMASHIKI_LOCAL_LLM_BASE_URL cannot abort every other entrypoint.
        # Bake the resolved URL into the gitignored e2e file: mix test does
        # not inherit the prepare-time environment.
        base_url = os.environ[LOCAL_LLM_BASE_URL_VAR]
        additions += f"""
[credentials.local-llm]
provider = "llamacpp"
model = {_toml_str(LOCAL_LLM_MODEL)}
base_url = {_toml_str(base_url)}
api_key = "unused-by-llama-server"

[presets.jcode]
plugin = "jcode"
options = {{ timeout_ms = 1800000, model = {_toml_str(LOCAL_LLM_MODEL)} }}
"""
        additions += _environment_stanza(
            name="e2e-jcode",
            preset="jcode",
            image="omashiki/agent-jcode:latest",
            credentials=["local-llm"],
            caches=[],
            cpus=1.0,
            memory="1GB",
            pids=256,
        )
    E2E_CONFIG.write_text(base + additions, encoding="utf-8")
    print(f"snapshots ready: {SNAPSHOT_ROOT}")
    print(f"config ready: {E2E_CONFIG}")
    if opencode_ready:
        print("OpenCode snapshots ready")
    if claude_ready:
        print("Claude Code credentials snapshot ready")
    if jcode_ready:
        print(f"jcode gateway target ready: {LOCAL_LLM_BASE_URL_VAR}")


def validate(provider: str) -> None:
    with fixture_lock():
        validate_locked(provider)


def validate_locked(provider: str) -> None:
    if provider == "claude":
        copy_private_file(
            CLAUDE_CREDENTIALS,
            SNAPSHOT_ROOT / "claude-credentials.json",
            "Claude Code credentials",
        )
    elif provider == "opencode":
        copy_private_file(OPENCODE_CONFIG, SNAPSHOT_ROOT / "opencode.json", "OpenCode config")
        copy_private_file(OPENCODE_AUTH, SNAPSHOT_ROOT / "auth.json", "OpenCode auth")
    else:
        raise SystemExit(f"unknown provider validation target: {provider}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("wipe", "prepare", "validate"))
    parser.add_argument("provider", nargs="?")
    args = parser.parse_args()
    if args.command == "validate":
        if not args.provider:
            raise SystemExit("validate requires a provider: opencode or claude")
        validate(args.provider)
    elif args.command == "prepare":
        prepare(args.provider or "all")
    else:
        wipe()


if __name__ == "__main__":
    main()
