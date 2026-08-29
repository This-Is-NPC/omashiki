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
JCODE_STUB_BASE_URL = "http://127.0.0.1:8787/v1"
JCODE_STUB_MODEL = "fake-model"
JCODE_STUB_SCENARIO = "python-hello"
RUNTIME_HANDLERS = ("runc", "kata")
PROVIDERS = ("all", "opencode", "claude", "jcode", "jcode-stub")
PROVIDER_PLUGINS = {
    "opencode": "opencode",
    "claude": "claude-code",
    "jcode": "jcode",
}
RUNTIME_SETTINGS = {
    "runc": {"memory": "2GB", "timeout_ms": 900000, "tmpfs_size_mb": 512},
    "kata": {"memory": "4GB", "timeout_ms": 1800000, "tmpfs_size_mb": 1024},
}


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
    if os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
        wipe_locked()
    else:
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


def _runtime_settings(runtime_handler: str) -> dict[str, int | str]:
    try:
        return RUNTIME_SETTINGS[runtime_handler]
    except KeyError:
        raise SystemExit(
            f"unknown runtime handler: {runtime_handler}; choose one of {', '.join(RUNTIME_HANDLERS)}"
        ) from None


def _normalize_base_runtime(base: str) -> str:
    """Make the checked-in legacy Docker runtime explicit runc for E2E loads."""
    return base.replace(
        "[runtimes.docker.debian.images]", "[runtimes.docker.runc.debian.images]"
    ).replace('runtime = "docker.debian"', 'runtime = "docker.runc.debian"')


def _strip_loadtest_local(base: str) -> str:
    """Exclude unrelated machine-local credentials from the isolated E2E config."""
    begin = "# >>> loadtest-local begin (do not commit)"
    end = "# <<< loadtest-local end"
    begin_at = base.find(begin)
    end_at = base.find(end)
    if begin_at == -1 and end_at == -1:
        return base
    if begin_at == -1 or end_at < begin_at:
        raise SystemExit("malformed loadtest-local marker block in omashiki.toml")
    suffix_at = end_at + len(end)
    return base[:begin_at].rstrip() + "\n" + base[suffix_at:].lstrip("\n")


def _strip_toml_table(base: str, header: str) -> str:
    """Remove one top-level TOML table and its body without parsing secrets."""
    lines = base.splitlines(keepends=True)
    start = next((index for index, line in enumerate(lines) if line.strip() == header), None)
    if start is None:
        return base
    finish = next(
        (index for index in range(start + 1, len(lines)) if lines[index].startswith("[")),
        len(lines),
    )
    return "".join(lines[:start] + lines[finish:]).rstrip()


def _runtime_catalog_stanza(runtime_handler: str, plugins: list[str]) -> str:
    images = {
        "opencode": "omashiki/agent:latest",
        "claude-code": "omashiki/agent-claude:latest",
        "jcode": "omashiki/agent-jcode:latest",
    }
    entries = "\n".join(
        f"{plugin} = {_toml_str(images[plugin])}" for plugin in plugins
    )
    return f"""

[runtimes.docker.{runtime_handler}.debian.images]
{entries}
"""


def _jcode_configuration(provider: str) -> dict[str, str]:
    if provider == "jcode":
        base_url = os.environ.get(LOCAL_LLM_BASE_URL_VAR)
        if not base_url:
            raise SystemExit(
                f"{LOCAL_LLM_BASE_URL_VAR} is unset; jcode needs the local model server, "
                f"for example {LOCAL_LLM_BASE_URL_VAR}=http://<host>:8080/v1"
            )
        return {
            "credential": "local-llm",
            "provider": "llamacpp",
            "model": LOCAL_LLM_MODEL,
            "base_url": base_url,
            "preset": "jcode",
        }
    if provider == "jcode-stub":
        # The gateway runs on the host, so its upstream is the host loopback,
        # not an address reachable from the agent container.
        return {
            "credential": "jcode-stub",
            "provider": "openai",
            "model": JCODE_STUB_MODEL,
            "base_url": JCODE_STUB_BASE_URL,
            "preset": "jcode-stub",
        }
    raise SystemExit(f"unknown jcode configuration target: {provider}")


def _jcode_stanza(runtime_handler: str, provider: str) -> str:
    target = _jcode_configuration(provider)
    settings = _runtime_settings(runtime_handler)
    api_key = (
        "unused-by-the-stub"
        if target["provider"] == "openai"
        else "unused-by-llama-server"
    )
    return f"""
[credentials.{target["credential"]}]
provider = {_toml_str(target["provider"])}
model = {_toml_str(target["model"])}
base_url = {_toml_str(target["base_url"])}
api_key = {_toml_str(api_key)}

[presets.{target["preset"]}]
plugin = "jcode"
options = {{ timeout_ms = {settings["timeout_ms"]}, model = {_toml_str(target["model"])} }}
""" + _environment_stanza(
        name="e2e-jcode",
        preset=target["preset"],
        runtime_handler=runtime_handler,
        credentials=[target["credential"]],
        caches=[],
        cpus=1.0,
        memory="2GB" if runtime_handler == "kata" else "1GB",
        pids=256,
        timeout_ms=settings["timeout_ms"],
    )


def _environment_stanza(
    *,
    name: str,
    preset: str,
    runtime_handler: str = "runc",
    credentials: list[str],
    caches: list[str],
    cpus: float,
    memory: str,
    pids: int,
    timeout_ms: int = 900000,
    network: str = "restricted",
) -> str:
    creds = ", ".join(_toml_str(item) for item in credentials)
    cache_items = ", ".join(_toml_str(item) for item in caches)
    return f"""
[environments.{name}]
preset = {_toml_str(preset)}
runtime = {_toml_str(f"docker.{runtime_handler}.debian")}
sink = "git"
packages = []
executables = ["git"]
credentials = [{creds}]
caches = [{cache_items}]
timeout_ms = {timeout_ms}
network = {_toml_str(network)}
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


def prepare(runtime_handler: str = "runc", provider: str = "all") -> None:
    # A one-argument provider invocation was the original interface. Keep it
    # usable while requiring every matrix task to pass the handler explicitly.
    if runtime_handler in PROVIDERS and provider == "all":
        provider = runtime_handler
        runtime_handler = "runc"
    elif runtime_handler in PROVIDERS and provider in RUNTIME_HANDLERS:
        # Also accept the provider-first spelling while callers migrate from
        # `prepare <provider>` to the explicit two-argument form.
        runtime_handler, provider = provider, runtime_handler

    if os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
        prepare_locked(runtime_handler, provider)
    else:
        with fixture_lock():
            prepare_locked(runtime_handler, provider)


def prepare_locked(runtime_handler: str, provider: str = "all") -> None:
    if runtime_handler in PROVIDERS and provider == "all":
        provider = runtime_handler
        runtime_handler = "runc"
    elif runtime_handler in PROVIDERS and provider in RUNTIME_HANDLERS:
        runtime_handler, provider = provider, runtime_handler

    _runtime_settings(runtime_handler)
    if provider not in PROVIDERS:
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

    # Both jcode targets use the gateway; only the real local-model target needs
    # a caller-supplied upstream URL. The stub URL is deliberately host-local.
    if provider in ("all", "jcode", "jcode-stub"):
        _jcode_configuration("jcode" if provider == "all" else provider)
        jcode_ready = True

    base = _normalize_base_runtime(
        _strip_loadtest_local(
            (ROOT / "omashiki.toml").read_text(encoding="utf-8").rstrip()
        )
    )
    if runtime_handler == "runc":
        base = _strip_toml_table(base, "[runtimes.docker.kata.debian.images]")
    additions = """

[repositories.overture]
path = "overture"
base_branch = "main"
"""
    runtime_plugins = []
    if opencode_ready:
        runtime_plugins.append(PROVIDER_PLUGINS["opencode"])
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
            runtime_handler=runtime_handler,
            credentials=["e2e-opencode"],
            caches=["global"],
            cpus=2.0,
            memory=_runtime_settings(runtime_handler)["memory"],
            pids=256,
            timeout_ms=_runtime_settings(runtime_handler)["timeout_ms"],
        )
    if claude_ready:
        runtime_plugins.append(PROVIDER_PLUGINS["claude"])
        credentials = SNAPSHOT_ROOT / "claude-credentials.json"
        additions += f"""
[host_credentials.e2e-claude]
kind = "claude-code"
credentials = {_toml_str(str(credentials))}
"""
        additions += _environment_stanza(
            name="e2e-claude",
            preset="claude-code",
            runtime_handler=runtime_handler,
            credentials=["e2e-claude"],
            caches=["global"],
            cpus=2.0,
            memory=_runtime_settings(runtime_handler)["memory"],
            pids=256,
            timeout_ms=_runtime_settings(runtime_handler)["timeout_ms"],
        )
    if jcode_ready:
        runtime_plugins.append(PROVIDER_PLUGINS["jcode"])
        additions += _jcode_stanza(
            runtime_handler,
            "jcode" if provider == "all" else provider,
        )
    if (
        runtime_handler == "kata"
        and "[runtimes.docker.kata.debian.images]" not in base
    ):
        additions += _runtime_catalog_stanza(runtime_handler, runtime_plugins)
    E2E_CONFIG.write_text(base + additions, encoding="utf-8")
    print(f"snapshots ready: {SNAPSHOT_ROOT}")
    print(f"config ready: {E2E_CONFIG}")
    if opencode_ready:
        print("OpenCode snapshots ready")
    if claude_ready:
        print("Claude Code credentials snapshot ready")
    if jcode_ready:
        if provider == "jcode-stub":
            print(f"jcode gateway target ready: {JCODE_STUB_BASE_URL} ({JCODE_STUB_SCENARIO})")
        else:
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
    parser.add_argument("runtime_handler", nargs="?")
    parser.add_argument("provider", nargs="?")
    args = parser.parse_args()
    if args.command == "validate":
        if not args.runtime_handler:
            raise SystemExit("validate requires a provider: opencode or claude")
        validate(args.runtime_handler)
    elif args.command == "prepare":
        prepare(args.runtime_handler or "runc", args.provider or "all")
    else:
        wipe()


if __name__ == "__main__":
    main()
