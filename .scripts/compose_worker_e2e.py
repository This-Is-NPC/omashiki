#!/usr/bin/env python3
"""Packaged manager+worker Compose E2E.

Builds and starts examples/compose.manager.yml and examples/compose.worker.yml,
enrolls the worker against host.docker.internal, and admits a jcode-stub hello job.

The release image runtime stage stays on alpine:3.22 (not 3.19) so OpenSSL matches
the elixir:1.17-alpine builder OTP crypto NIF.
"""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from host_worker_e2e import (
    E2EError,
    Blocker,
    E2E_CONFIG,
    INSTRUCTIONS,
    LOCK_PATH,
    OVERTURE,
    ROOT,
    api_request,
    docker_available,
    labelled_containers,
    patch_overture_remote,
    port_busy,
    remove_labelled_containers,
    run,
    stop_process,
    wait_http,
    watch_container_creates,
)

MANAGER_PORT = 4013
ENROLL_PORT = 4014
FAKE_LLM_PORT = 8788
JOB_TIMEOUT_SEC = 180
MANAGER_PROJECT = "omashiki-e2e-mgr"
WORKER_PROJECT = "omashiki-e2e-wrk"
MANAGER_COMPOSE = ROOT / "examples" / "compose.manager.yml"
WORKER_COMPOSE = ROOT / "examples" / "compose.worker.yml"
STUB_LLM_HOST_URL = "http://127.0.0.1:8787/v1"
# Legacy host-reachable URL from earlier harness revisions; migrated on load.
CONTAINER_LLM_HOST_URL = "http://host.docker.internal:8788/v1"
# Manager reaches the stub via Docker DNS on the compose network (Linux
# host.docker.internal often cannot route published host ports back in).
COMPOSE_FAKE_LLM_URL = "http://fake-llm:8788/v1"
ENROLL_MANAGER_URL = f"http://host.docker.internal:{MANAGER_PORT}"


def safe_secret() -> str:
    """Return a token_urlsafe string safe as a CLI positional value."""
    while True:
        token = secrets.token_urlsafe(32)
        if not token.startswith("-"):
            return token


def patch_llm_base_url(config_text: str) -> str:
    """Rewrite the stub LLM URL so the manager container reaches the compose fake LLM."""
    if COMPOSE_FAKE_LLM_URL in config_text:
        return config_text
    if CONTAINER_LLM_HOST_URL in config_text:
        return config_text.replace(CONTAINER_LLM_HOST_URL, COMPOSE_FAKE_LLM_URL)
    if STUB_LLM_HOST_URL not in config_text:
        raise E2EError(
            f"missing stub LLM URL {STUB_LLM_HOST_URL!r} in {E2E_CONFIG}"
        )
    return config_text.replace(STUB_LLM_HOST_URL, COMPOSE_FAKE_LLM_URL)


def render_worker_override(overture_path: Path) -> str:
    """Compose override that bind-mounts overture at the same absolute host path."""
    overture = overture_path.resolve()
    return (
        "services:\n"
        "  worker:\n"
        "    volumes:\n"
        f"      - {overture}:{overture}\n"
    )


def render_manager_override(
    repo_root: Path,
    *,
    config_name: str = "omashiki.e2e.toml",
) -> str:
    """Compose override: repo config mount + in-network fake LLM for the gateway."""
    repo = repo_root.resolve()
    fake_script = repo / ".scripts" / "loadtest" / "fake_llm.py"
    return (
        "services:\n"
        "  fake-llm:\n"
        "    image: python:3.12-alpine\n"
        "    command:\n"
        "      - python3\n"
        "      - /scripts/fake_llm.py\n"
        "      - --host\n"
        "      - 0.0.0.0\n"
        "      - --port\n"
        "      - \"8788\"\n"
        "      - --model\n"
        "      - fake-model\n"
        "      - --scenario\n"
        "      - python-hello\n"
        "      - --lat-ms\n"
        "      - \"0\"\n"
        "      - --jitter-pct\n"
        "      - \"0\"\n"
        "    volumes:\n"
        f"      - {fake_script}:/scripts/fake_llm.py:ro\n"
        "    expose:\n"
        "      - \"8788\"\n"
        "    healthcheck:\n"
        "      test:\n"
        "        - CMD\n"
        "        - python3\n"
        "        - -c\n"
        "        - import urllib.request; urllib.request.urlopen('http://127.0.0.1:8788/healthz')\n"
        "      interval: 1s\n"
        "      timeout: 3s\n"
        "      retries: 20\n"
        "      start_period: 2s\n"
        "  manager:\n"
        "    depends_on:\n"
        "      db:\n"
        "        condition: service_healthy\n"
        "      fake-llm:\n"
        "        condition: service_healthy\n"
        "    environment:\n"
        f"      OMASHIKI_CONFIG: /config/repo/{config_name}\n"
        "    volumes:\n"
        f"      - {repo}:/config/repo:ro\n"
    )


def manager_override_volume(repo_root: Path) -> tuple[str, str]:
    repo = str(repo_root.resolve())
    return repo, "/config/repo"


def worker_override_volume(overture_path: Path) -> tuple[str, str]:
    """Return the host:container volume pair for the overture bind mount."""
    overture = str(overture_path.resolve())
    return overture, overture


def enroll_argv(*, worker_token: str, enroll_secret: str) -> list[str]:
    return [
        "python3",
        str(ROOT / ".scripts" / "enroll_worker.py"),
        "--worker-url",
        f"http://127.0.0.1:{ENROLL_PORT}",
        "--manager-url",
        ENROLL_MANAGER_URL,
        "--worker-token",
        worker_token,
        "--enroll-secret",
        enroll_secret,
    ]


FAKE_LLM_SCRIPT = ROOT / ".scripts" / "loadtest" / "fake_llm.py"


def pid_listening_on_port(port: int) -> int | None:
    """Return the PID listening on loopback TCP *port*, if discoverable."""
    for cmd in (
        ["ss", "-ltnp", f"sport = :{port}"],
        ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
    ):
        if not shutil.which(cmd[0]):
            continue
        result = run(cmd, check=False)
        if result.returncode != 0:
            continue
        for line in result.stdout.splitlines():
            if "pid=" in line:
                for token in line.split(","):
                    if token.startswith("pid="):
                        return int(token.removeprefix("pid="))
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "python3":
                try:
                    return int(parts[1])
                except ValueError:
                    continue
    return None


def harness_fake_llm_process(pid: int) -> bool:
    """True when *pid* is this harness's loadtest fake LLM."""
    cmdline_path = Path(f"/proc/{pid}/cmdline")
    if not cmdline_path.is_file():
        return False
    cmdline = cmdline_path.read_bytes().replace(b"\x00", b" ").decode(
        errors="replace"
    )
    return "fake_llm.py" in cmdline and str(FAKE_LLM_SCRIPT) in cmdline


def stop_leftover_harness_fake_llm(port: int = FAKE_LLM_PORT) -> None:
    pid = pid_listening_on_port(port)
    if pid is None or not harness_fake_llm_process(pid):
        return
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            return
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass


def teardown_compose_env() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("OMASHIKI_HOST_HOME", str(Path.home()))
    env.setdefault("OMASHIKI_ENROLL_SECRET", "teardown")
    return env


E2E_BRANCHES = ("e2e-hello-world", "e2e-hello-world-run-001")


def cleanup_overture_fixture() -> None:
    """Drop stale hello-job branches and worktrees from prior compose E2E runs."""
    if not (OVERTURE / ".git").is_dir():
        return
    worktree_root = OVERTURE / ".omashiki-worktrees"
    if worktree_root.is_dir():
        shutil.rmtree(worktree_root, ignore_errors=True)
    for branch in E2E_BRANCHES:
        run(["git", "-C", str(OVERTURE), "branch", "-D", branch], check=False)
    for branch in E2E_BRANCHES:
        run(
            ["git", "-C", str(OVERTURE), "update-ref", "-d", f"refs/heads/{branch}"],
            check=False,
        )


def cleanup_compose_e2e_cache() -> None:
    """Remove mirror/worktree state left by compose enroll hosts."""
    host_home = Path.home()
    mirrors = host_home / ".cache" / "omashiki" / "mirrors"
    for host in ("host.docker.internal", "127.0.0.1"):
        mirror_root = mirrors / host
        if not mirror_root.exists():
            continue
        try:
            shutil.rmtree(mirror_root)
        except OSError:
            run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-v",
                    f"{host_home}/.cache/omashiki:/cache",
                    "alpine:3.22",
                    "rm",
                    "-rf",
                    f"/cache/mirrors/{host}",
                ],
                check=False,
            )


def teardown_leftovers() -> None:
    """Remove orphaned compose E2E stacks and harness-owned fake LLM."""
    env = teardown_compose_env()
    run(
        [
            "docker",
            "compose",
            "-p",
            MANAGER_PROJECT,
            "-f",
            str(MANAGER_COMPOSE),
            "down",
            "-v",
        ],
        env=env,
        check=False,
    )
    run(
        [
            "docker",
            "compose",
            "-p",
            WORKER_PROJECT,
            "-f",
            str(WORKER_COMPOSE),
            "down",
            "-v",
        ],
        env=env,
        check=False,
    )
    cleanup_overture_fixture()
    cleanup_compose_e2e_cache()
    stop_leftover_harness_fake_llm()


def ensure_api_token() -> str | None:
    status, _ = api_request("POST", "/api/v1/jobs", {"schema_version": 1}, port=MANAGER_PORT)
    if status == 401:
        username = f"compose_e2e_{secrets.token_hex(4)}"
        password = secrets.token_urlsafe(24)
        signup_status, signup_body = api_request(
            "POST", "/api/v1/sessions/signup",
            {"email": f"{username}@example.test", "username": username, "password": password, "name": "Compose Worker E2E"},
            port=MANAGER_PORT,
        )
        if signup_status == 201 and signup_body.get("data", {}).get("token"):
            return signup_body["data"]["token"]
        if signup_status == 409:
            retry_status, _ = api_request("POST", "/api/v1/jobs", {"schema_version": 1}, port=MANAGER_PORT)
            if retry_status in (400, 422):
                return ""
            raise E2EError(f"signup closed and auth-none probe returned HTTP {retry_status}")
        raise E2EError(f"signup failed with HTTP {signup_status}: {signup_body}")
    if status in (400, 422):
        return None
    if status == 202:
        raise E2EError("probe job admission unexpectedly succeeded")
    raise E2EError(f"unexpected probe response HTTP {status}")


class Harness:
    def __init__(self, *, skip_prepare: bool = False) -> None:
        self.skip_prepare = skip_prepare
        self.lock_handle: object | None = None
        self.worker_token = secrets.token_urlsafe(32)
        self.enroll_secret = safe_secret()
        self.fake_llm: subprocess.Popen | None = None
        self.api_token: str | None = None
        self.correlation_id = f"compose-worker-e2e-{secrets.token_hex(4)}"
        self.container_watch_stop = threading.Event()
        self.container_watch_seen: list[dict[str, str]] = []
        self.container_watch_thread: threading.Thread | None = None
        self.override_path: Path | None = None
        self.manager_override_path: Path | None = None
        self.host_home = Path.home()

    def acquire_lock(self) -> None:
        if os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
            return
        if LOCK_PATH.parent.is_symlink() or (LOCK_PATH.parent.exists() and not LOCK_PATH.parent.is_dir()):
            raise Blocker("refusing unsafe .omashiki lock directory")
        LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
        lock_handle = LOCK_PATH.open("w")
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Blocker("another E2E is already running (.omashiki/e2e.lock)") from None
        self.lock_handle = lock_handle

    def release_lock(self) -> None:
        if self.lock_handle is None:
            return
        try:
            fcntl.flock(self.lock_handle.fileno(), fcntl.LOCK_UN)
        finally:
            self.lock_handle.close()
            self.lock_handle = None

    def compose_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update({
            "MANAGER_PORT": str(MANAGER_PORT),
            "OMASHIKI_ENROLL_PORT": str(ENROLL_PORT),
            "OMASHIKI_WORKER_TOKEN": self.worker_token,
            "OMASHIKI_ENROLL_SECRET": self.enroll_secret,
            "SECRET_KEY_BASE": "compose-worker-e2e-secret",
            "OMASHIKI_CONFIG_HOST": str(E2E_CONFIG.resolve()),
            "OMASHIKI_HOST_HOME": str(self.host_home),
        })
        return env

    def prepare_fixture(self) -> None:
        if self.skip_prepare or os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
            return
        env = os.environ.copy()
        env["OMASHIKI_E2E_LOCK_HELD"] = "1"
        run(["mise", "run", "e2e:prepare:runc:jcode-stub"], env=env)
        run(["mise", "run", "images"], env=env)

    def patch_config(self) -> None:
        if not E2E_CONFIG.is_file():
            raise E2EError(f"missing prepared config: {E2E_CONFIG}")
        if not (OVERTURE / ".git").is_dir():
            raise E2EError("overture fixture is not initialized; run e2e prepare first")
        original = E2E_CONFIG.read_text(encoding="utf-8")
        patched = patch_overture_remote(original, OVERTURE)
        patched = patch_llm_base_url(patched)
        if patched != original:
            E2E_CONFIG.write_text(patched, encoding="utf-8")

    def write_worker_override(self) -> Path:
        handle = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix="omashiki-compose-worker-", suffix=".yml", delete=False)
        handle.write(render_worker_override(OVERTURE))
        handle.close()
        self.override_path = Path(handle.name)
        return self.override_path

    def write_manager_override(self) -> Path:
        handle = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix="omashiki-compose-manager-", suffix=".yml", delete=False)
        handle.write(render_manager_override(ROOT))
        handle.close()
        self.manager_override_path = Path(handle.name)
        return self.manager_override_path

    def compose(self, project: str, compose_files: list[Path], *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        cmd = ["docker", "compose", "-p", project]
        for compose_file in compose_files:
            cmd.extend(["-f", str(compose_file)])
        cmd.extend(args)
        return run(cmd, env=self.compose_env(), check=check)

    def start_compose_stacks(self) -> None:
        manager_override = self.write_manager_override()
        worker_override = self.write_worker_override()
        self.compose(MANAGER_PROJECT, [MANAGER_COMPOSE, manager_override], "up", "-d", "--build")
        self.compose(WORKER_PROJECT, [WORKER_COMPOSE, worker_override], "up", "-d", "--build")
        wait_http(f"http://127.0.0.1:{MANAGER_PORT}/api/v1/health", timeout=120)
        wait_http(f"http://127.0.0.1:{ENROLL_PORT}/healthz", timeout=120)

    def enroll_worker(self) -> None:
        run(enroll_argv(worker_token=self.worker_token, enroll_secret=self.enroll_secret))

    def start_container_watch(self) -> None:
        self.container_watch_stop.clear()
        self.container_watch_seen = []
        def watch() -> None:
            watch_container_creates(self.container_watch_stop, self.container_watch_seen, self.correlation_id)
        self.container_watch_thread = threading.Thread(target=watch, name="compose-worker-container-watch", daemon=True)
        self.container_watch_thread.start()

    def stop_container_watch(self) -> None:
        self.container_watch_stop.set()
        if self.container_watch_thread is not None:
            self.container_watch_thread.join(timeout=2)
            self.container_watch_thread = None

    def admit_job(self) -> str:
        self.api_token = ensure_api_token()
        request = {
            "schema_version": 1,
            "idempotency_key": "compose-worker-e2e-hello",
            "correlation_id": self.correlation_id,
            "repo": "overture",
            "environment": "e2e-jcode",
            "payload": {"instruction": INSTRUCTIONS, "title": "e2e-hello-world"},
            "priority": 0,
        }
        status, body = api_request("POST", "/api/v1/jobs", request, self.api_token, port=MANAGER_PORT)
        if status != 202:
            raise E2EError(f"job admission failed with HTTP {status}: {body}")
        return body["data"]["id"]

    def wait_for_container_proof(self, job_id: str) -> list[dict[str, str]]:
        deadline = time.monotonic() + JOB_TIMEOUT_SEC
        while time.monotonic() < deadline:
            if self.container_watch_seen:
                return self.container_watch_seen
            containers = labelled_containers(self.correlation_id)
            if containers:
                return containers
            status, body = api_request("GET", f"/api/v1/jobs/{job_id}/result", token=self.api_token, port=MANAGER_PORT)
            if status == 200 and body.get("data", {}).get("status") in {"succeeded", "failed", "cancelled"}:
                terminal = body.get("data", {})
                if terminal.get("status") != "succeeded":
                    raise E2EError(f"job finished before a labelled host container was observed: {terminal}")
                break
            time.sleep(0.1)
        grace_deadline = time.monotonic() + 3
        while time.monotonic() < grace_deadline:
            if self.container_watch_seen:
                return self.container_watch_seen
            seen = labelled_containers(self.correlation_id)
            if seen:
                return seen
            time.sleep(0.05)
        raise E2EError("no labelled Docker container observed on the host while the job ran")

    def wait_for_result(self, job_id: str) -> dict:
        deadline = time.monotonic() + JOB_TIMEOUT_SEC
        last: dict = {}
        while time.monotonic() < deadline:
            status, body = api_request("GET", f"/api/v1/jobs/{job_id}/result", token=self.api_token, port=MANAGER_PORT)
            if status != 200:
                time.sleep(1)
                continue
            last = body.get("data", {})
            if last.get("status") == "succeeded":
                return last
            if last.get("status") in {"failed", "cancelled"}:
                raise E2EError(f"job finished with status {last.get('status')}: {last}")
            time.sleep(1)
        raise E2EError(f"timed out waiting for job result: {last}")

    def assert_hello_on_remote(self, result: dict) -> None:
        if result.get("worktree_clean") is not True:
            raise E2EError(f"worktree not clean: {result}")
        branch = result.get("branch")
        if not branch:
            raise E2EError(f"missing branch in result: {result}")
        show = run(["git", "-C", str(OVERTURE), "show", f"{branch}:hello.py"], check=False)
        if show.returncode != 0 or "Hello, World!" not in show.stdout:
            raise E2EError(f"hello.py missing or wrong on overture remote branch {branch}: {show.stdout}{show.stderr}")

    def compose_down(self) -> None:
        if self.override_path is not None:
            self.compose(WORKER_PROJECT, [WORKER_COMPOSE, self.override_path], "down", "-v", check=False)
        if self.manager_override_path is not None:
            self.compose(MANAGER_PROJECT, [MANAGER_COMPOSE, self.manager_override_path], "down", "-v", check=False)
        else:
            self.compose(MANAGER_PROJECT, [MANAGER_COMPOSE], "down", "-v", check=False)

    def cleanup(self) -> None:
        stop_process("fake-llm", self.fake_llm)
        self.fake_llm = None
        self.compose_down()
        if self.override_path is not None and self.override_path.exists():
            self.override_path.unlink()
            self.override_path = None
        if self.manager_override_path is not None and self.manager_override_path.exists():
            self.manager_override_path.unlink()
            self.manager_override_path = None
        remove_labelled_containers()
        self.release_lock()

    def preflight(self) -> None:
        if not shutil.which("docker"):
            raise Blocker("docker is not installed")
        if not docker_available():
            raise Blocker("docker daemon is not reachable")
        for port, label in ((MANAGER_PORT, "manager"), (ENROLL_PORT, "worker enroll")):
            if port_busy(port):
                raise Blocker(f"port {port} is already in use ({label})")

    def run(self) -> None:
        teardown_leftovers()
        self.preflight()
        self.acquire_lock()
        try:
            self.prepare_fixture()
            self.patch_config()
            self.start_compose_stacks()
            self.enroll_worker()
            self.start_container_watch()
            time.sleep(0.3)
            remove_labelled_containers()
            job_id = self.admit_job()
            try:
                containers = self.wait_for_container_proof(job_id)
                print(f"observed {len(containers)} labelled host container(s): {containers}", flush=True)
            finally:
                self.stop_container_watch()
            result = self.wait_for_result(job_id)
            self.assert_hello_on_remote(result)
            print("compose-worker E2E passed", flush=True)
        finally:
            self.cleanup()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-prepare", action="store_true", help="skip mise prepare/build (caller already ran them under the e2e lock)")
    args = parser.parse_args(argv)
    harness = Harness(skip_prepare=args.skip_prepare)
    try:
        harness.run()
    except Blocker as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    except E2EError as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
