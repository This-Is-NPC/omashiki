"""
Shared helpers for the mise tasks under .mise/tasks/.

Each task is a small script that does one thing; anything two of them need
lives here. Nothing in this module knows the order tasks run in — that is
mise's job, expressed as `depends` in the task headers.
"""

import os
import pathlib
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "server"
ASSETS = SERVER / "assets"
CONFIG_FILE = ROOT / "omashiki.toml"

# Images the orchestrator provisions sandboxes from, and where each is built.
# Both runtimes ship active, so a working checkout needs both: an active
# runtime with no image fails when someone starts a task rather than at boot,
# which is the worse place to find out.
AGENT_IMAGES = {
    "omashiki/agent:latest": ["agent/"],
    "omashiki/agent-claude:latest": ["-f", "agent/Dockerfile.claude", "agent/"],
}


def config() -> dict:
    """omashiki.toml, or an empty mapping. Absent is fine — every value has a
    default further down the chain (see server/config/runtime.exs)."""
    if not CONFIG_FILE.exists():
        return {}
    with CONFIG_FILE.open("rb") as fh:
        return tomllib.load(fh)


def task_env() -> dict:
    """The caller's environment plus the ports from omashiki.toml, for
    anything a task spawns. An explicit variable always wins over the file, so
    CI keeps overriding without editing it.

    This lives here rather than in mise's `[env] _.source` on purpose: that
    hook runs while mise is still assembling the environment, so a script that
    reaches for the mise-managed python deadlocks. Keeping it in Python is
    also what stops a second, weaker TOML parser appearing in shell.
    """
    cfg = config()
    env = {**os.environ}
    for var, (section, key) in (
        ("OMASHIKI_DB_PORT", ("db", "port")),
        ("PORT", ("app", "port")),
    ):
        value = cfg.get(section, {}).get(key)
        if value is not None and var not in os.environ:
            env[var] = str(value)
    return env


def run(cmd: list, cwd: pathlib.Path = SERVER, check: bool = True,
        env: dict | None = None) -> int:
    """Run a command, printing it first. Defaults to the task environment."""
    print(f"\n▶ {' '.join(str(c) for c in cmd)}", flush=True)
    result = subprocess.run(cmd, cwd=cwd, check=False, env=env or task_env())
    if check and result.returncode != 0:
        print(f"\n✖ Command failed (exit {result.returncode})", file=sys.stderr)
        sys.exit(result.returncode)
    return result.returncode


def compose(*args: str, check: bool = True) -> int:
    return run(["docker", "compose", *args], cwd=SERVER, check=check)


NODE_NAME = "omashiki@127.0.0.1"
NODE_COOKIE = "omashiki"


def node_name() -> str:
    return os.environ.get("OMASHIKI_NODE_NAME", NODE_NAME)


def node_cookie() -> str:
    return os.environ.get("OMASHIKI_NODE_COOKIE", NODE_COOKIE)


def erl_options(distributed: bool) -> str:
    """Flags for the BEAM a task starts.

    `+Bc` keeps Ctrl-C from killing the BEAM before its shutdown hooks run, and
    every task wants it.

    `distributed` additionally names the node. An unnamed BEAM is
    `nonode@nohost` and there is nothing for `--remsh` to attach to: during a
    seventeen-minute deadlock the only way to ask a wedged process what it was
    doing was `Process.info(pid, :current_stacktrace)`, and there was no way in
    to make the call. Only the long-running server asks for this — giving a
    one-shot `mix ecto.migrate` the same name would refuse to start whenever the
    server already held it.

    `-name omashiki@127.0.0.1` rather than `-sname omashiki`, because the
    address is the part that has to be right. The distribution listener is
    pinned to loopback below, and a short name resolves through whatever the
    host's name service says: on a machine with no /etc/hosts entry for its own
    hostname it comes back as a link-local IPv6 address, and the console cannot
    reach a socket bound to 127.0.0.1. Naming the node after the interface it
    listens on removes the resolution step entirely.

    The cookie is set on purpose rather than left to the random one in
    ~/.erlang.cookie, because a value that changes per machine is a value no
    documented `--remsh` line can use. That is only safe next to the loopback
    pin: with a known cookie on a routable interface the console is remote code
    execution for the whole LAN, and `app.host` is 0.0.0.0 by default because
    agent containers need the bridge. Both are overridable.
    """
    options = ["+Bc"]

    if distributed:
        options += [
            f"-name {node_name()}",
            f"-setcookie {node_cookie()}",
            "-kernel inet_dist_use_interface {127,0,0,1}",
        ]

    return " ".join(options)


def mix(*args: str, check: bool = True, distributed: bool = False) -> int:
    return run(["mix", *args], cwd=SERVER, check=check,
               env={**task_env(), "ELIXIR_ERL_OPTIONS": erl_options(distributed)})


def docker_lines(args: list) -> list:
    """Run a docker query and return its non-empty output lines."""
    out = subprocess.run(args, capture_output=True, text=True)
    return [line for line in out.stdout.splitlines() if line.strip()]


def image_exists(tag: str) -> bool:
    return subprocess.run(
        ["docker", "image", "inspect", tag], capture_output=True
    ).returncode == 0
