#!/usr/bin/env python3
"""Host-only manager+worker Docker E2E.

Starts one manager BEAM and one worker BEAM on this machine. The worker talks
to the host Docker daemon; the manager does not start ContainerManager.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
import threading
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "server"
E2E_CONFIG = ROOT / "omashiki.e2e.toml"
OVERTURE = ROOT / "overture"
LOCK_PATH = ROOT / ".omashiki" / "e2e.lock"
LOG_DIR = ROOT / ".omashiki"
MANAGER_PORT = 4011
DB_NAME = "omashiki_host_e2e"
FAKE_LLM_PORT = 8787
JOB_TIMEOUT_SEC = 180
# A worker reports a container change within a second; a census corrects the
# list every ten seconds. Twenty seconds covers both with margin.
FLEET_TIMEOUT_SEC = 20
FLEET_CONTAINER_STATES = {"created", "running", "exited", "removing"}

INSTRUCTIONS = """\
Create a Python file named hello.py at the repository root. It must print
exactly `Hello, World!` followed by a newline when run with `python3 hello.py`.
Commit the file with a concise commit message. Do not create or modify any
other file.
"""


class E2EError(RuntimeError):
    pass


class Blocker(E2EError):
    pass


def default_db_port() -> int:
    env = os.environ.get("OMASHIKI_DB_PORT")
    if env:
        return int(env)
    config_path = ROOT / "omashiki.toml"
    if config_path.is_file():
        with config_path.open("rb") as handle:
            cfg = tomllib.load(handle)
        port = cfg.get("db", {}).get("port")
        if port is not None:
            return int(port)
    return 5442


def patch_overture_remote(config_text: str, overture_path: Path) -> str:
    """Ensure ``[repositories.overture]`` includes a file:// remote."""
    remote = f"file://{overture_path.resolve()}"
    header = "[repositories.overture]"
    if header not in config_text:
        raise ValueError(f"missing {header} in e2e config")

    lines = config_text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == header)
    end = start + 1
    while end < len(lines) and not (
        lines[end].startswith("[") and lines[end].endswith("]")
    ):
        end += 1

    section = lines[start:end]
    remote_line = f'remote = "{remote}"'
    replaced = False
    for index, line in enumerate(section):
        if line.strip().startswith("remote"):
            section[index] = remote_line
            replaced = True
            break
    if not replaced:
        insert_at = 1
        for index, line in enumerate(section[1:], start=1):
            if line.strip().startswith("path"):
                insert_at = index + 1
                break
        section.insert(insert_at, remote_line)

    return "\n".join(lines[:start] + section + lines[end:]) + (
        "\n" if config_text.endswith("\n") else ""
    )


def manager_env(
    *,
    worker_token: str,
    db_port: int,
    config_path: Path,
) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "MIX_ENV": "dev",
            "OMASHIKI_ROLE": "manager",
            "OMASHIKI_NODE": "core",
            "OMASHIKI_WORKER_TOKEN": worker_token,
            "OMASHIKI_CONFIG": str(config_path.resolve()),
            "PORT": str(MANAGER_PORT),
            "OMASHIKI_DB_NAME": DB_NAME,
            "OMASHIKI_AGENT_NETWORK_MODE": "host",
            "OMASHIKI_DB_PORT": str(db_port),
        }
    )
    return env


def worker_env(*, worker_token: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "MIX_ENV": "dev",
            "OMASHIKI_ROLE": "worker",
            "OMASHIKI_NODE": "worker-1",
            "OMASHIKI_MANAGER_URL": f"http://127.0.0.1:{MANAGER_PORT}",
            "OMASHIKI_WORKER_TOKEN": worker_token,
            "OMASHIKI_DOCKER_SOCKET_PATH": "/var/run/docker.sock",
            "OMASHIKI_AGENT_NETWORK_MODE": "host",
            "OMASHIKI_MAX_CONCURRENT_CONTAINERS": "1",
        }
    )
    env.pop("OMASHIKI_CONFIG", None)
    return env


def run(cmd: list[str], *, cwd: Path = ROOT, env: dict[str, str] | None = None,
        check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
    )
    if check and result.returncode != 0:
        raise E2EError(
            f"command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result


def port_busy(port: int) -> bool:
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.2)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def docker_available() -> bool:
    return run(["docker", "info"], check=False).returncode == 0


def postgres_available(db_port: int) -> bool:
    probe = run(
        [
            "docker",
            "compose",
            "exec",
            "-T",
            "db",
            "pg_isready",
            "-U",
            "postgres",
            "-d",
            "postgres",
        ],
        cwd=SERVER,
        check=False,
    )
    if probe.returncode == 0:
        return True
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", db_port)) == 0


def api_request(
    method: str,
    path: str,
    payload: dict | None = None,
    token: str | None = None,
    *,
    port: int = MANAGER_PORT,
    timeout: float = 30,
) -> tuple[int, dict]:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        method=method,
    )
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
    try:
        with urllib.request.urlopen(request, data=data, timeout=timeout) as response:
            body = response.read()
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {"raw": raw.decode(errors="replace")}
        return error.code, parsed


def ensure_api_token() -> str | None:
    status, _ = api_request("POST", "/api/v1/jobs", {"schema_version": 1})
    if status == 401:
        username = f"host_e2e_{secrets.token_hex(4)}"
        password = secrets.token_urlsafe(24)
        signup_status, signup_body = api_request(
            "POST",
            "/api/v1/sessions/signup",
            {
                "email": f"{username}@example.test",
                "username": username,
                "password": password,
                "name": "Host Worker E2E",
            },
        )
        if signup_status == 201 and signup_body.get("data", {}).get("token"):
            return signup_body["data"]["token"]
        if signup_status == 409:
            retry_status, _ = api_request("POST", "/api/v1/jobs", {"schema_version": 1})
            if retry_status in (400, 422):
                return ""
            raise E2EError(
                f"signup closed and auth-none probe returned HTTP {retry_status}"
            )
        raise E2EError(f"signup failed with HTTP {signup_status}: {signup_body}")
    if status in (400, 422):
        return None
    if status == 202:
        raise E2EError("probe job admission unexpectedly succeeded")
    raise E2EError(f"unexpected probe response HTTP {status}")


def labelled_containers(correlation_id: str | None = None) -> list[dict[str, str]]:
    args = ["docker", "ps", "--filter", "label=omashiki.job_scope_id"]
    if correlation_id:
        args.extend(["--filter", f"label=omashiki.correlation_id={correlation_id}"])
    args.extend(
        [
            "--format",
            '{{.ID}}\t{{.Label "omashiki.correlation_id"}}\t{{.Label "omashiki.job_scope_id"}}',
        ]
    )
    result = run(args, check=False)
    if result.returncode != 0:
        return []
    records: list[dict[str, str]] = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        records.append(
            {
                "id": parts[0],
                "correlation_id": parts[1],
                "scope_id": parts[2],
            }
        )
    return records


def remove_labelled_containers() -> None:
    listed = run(
        ["docker", "ps", "-aq", "--filter", "label=omashiki.job_scope_id"],
        check=False,
    )
    ids = listed.stdout.split()
    for container_id in ids:
        run(["docker", "rm", "-f", container_id], check=False)


def watch_container_creates(
    stop_event: threading.Event,
    seen: list[dict[str, str]],
    correlation_id: str,
) -> None:
    """Watch docker events so we catch short-lived agent containers."""
    proc = subprocess.Popen(
        [
            "docker",
            "events",
            "--filter",
            "type=container",
            "--filter",
            "event=create",
            "--filter",
            "label=omashiki.job_scope_id",
            "--format",
            "{{.Actor.ID}}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        while not stop_event.is_set() and proc.stdout is not None:
            line = proc.stdout.readline()
            if not line:
                break
            container_id = line.strip()
            if not container_id:
                continue
            corr = ""
            scope = ""
            inspect = run(
                [
                    "docker",
                    "inspect",
                    "--format",
                    '{{index .Config.Labels "omashiki.correlation_id"}}\t{{index .Config.Labels "omashiki.job_scope_id"}}',
                    container_id,
                ],
                check=False,
            )
            if inspect.returncode == 0:
                parts = inspect.stdout.strip().split("\t")
                if len(parts) == 2:
                    corr, scope = parts
                    if correlation_id and corr and corr != correlation_id:
                        continue
            seen.append(
                {
                    "id": container_id,
                    "correlation_id": corr,
                    "scope_id": scope,
                }
            )
            stop_event.set()
            return
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def fleet_container(fleet: dict, container_id: str) -> tuple[dict, dict] | None:
    """Find a Docker container in a ``GET /api/v1/fleet`` body.

    The Docker CLI prints short ids and the Engine API full ones, so either may
    be a prefix of the other.
    """
    for node in fleet.get("data", []):
        for container in node.get("containers", []):
            reported = container.get("id") or ""
            if reported and (reported.startswith(container_id) or container_id.startswith(reported)):
                return node, container
    return None


def fleet_report_problems(node: dict, container: dict, job_id: str, *, machine_id: str) -> list[str]:
    """What is wrong with the manager's view of the worker running ``job_id``."""
    problems = []
    if node.get("kind") != "worker":
        problems.append(f"node kind is {node.get('kind')!r}, expected 'worker'")
    if node.get("machine_id") != machine_id:
        problems.append(f"node is {node.get('machine_id')!r}, expected {machine_id!r}")
    if node.get("stale") is not False:
        problems.append("worker is reported stale while it runs a job")
    if node.get("capacity") != 1:
        problems.append(f"worker capacity is {node.get('capacity')!r}, expected 1")
    if container.get("job_id") != job_id:
        problems.append(f"container job_id is {container.get('job_id')!r}, expected {job_id!r}")
    if container.get("state") not in FLEET_CONTAINER_STATES:
        problems.append(f"container state is {container.get('state')!r}")
    return problems


def watch_fleet(stop_event: threading.Event, seen: list[dict], token: str | None) -> None:
    """Record every fleet snapshot with a container, so a short-lived one is kept."""
    while not stop_event.is_set():
        try:
            status, body = api_request("GET", "/api/v1/fleet", token=token, timeout=5)
        except OSError:
            status, body = 0, {}
        if status == 200 and any(node.get("containers") for node in body.get("data", [])):
            seen.append(body)
            del seen[:-500]
        stop_event.wait(0.1)


def wait_http(url: str, *, timeout: float = 90, process: subprocess.Popen | None = None) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise E2EError(f"process exited before {url} became ready")
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                if response.status == 200:
                    payload = json.loads(response.read())
                    if payload.get("status") == "ok":
                        return
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        time.sleep(0.5)
    raise E2EError(f"timed out waiting for {url}")


def start_process(
    name: str,
    cmd: list[str],
    env: dict[str, str],
    log_name: str,
) -> subprocess.Popen:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / log_name
    log_handle = log_path.open("w", encoding="utf-8")
    print(f"starting {name}: {' '.join(cmd)} -> {log_path}", flush=True)
    return subprocess.Popen(
        cmd,
        cwd=SERVER,
        env=env,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )


def stop_process(name: str, process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and process.poll() is None:
        time.sleep(0.2)
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


class Harness:
    def __init__(self, *, skip_prepare: bool = False) -> None:
        self.skip_prepare = skip_prepare
        self.lock_handle: object | None = None
        self.worker_token = secrets.token_urlsafe(32)
        self.db_port = default_db_port()
        self.fake_llm: subprocess.Popen | None = None
        self.manager: subprocess.Popen | None = None
        self.worker: subprocess.Popen | None = None
        self.api_token: str | None = None
        self.correlation_id = f"host-worker-e2e-{secrets.token_hex(4)}"
        self.container_watch_stop = threading.Event()
        self.container_watch_seen: list[dict[str, str]] = []
        self.container_watch_thread: threading.Thread | None = None
        self.fleet_watch_stop = threading.Event()
        self.fleet_seen: list[dict] = []
        self.fleet_watch_thread: threading.Thread | None = None

    def acquire_lock(self) -> None:
        if os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
            return
        if LOCK_PATH.parent.is_symlink() or (
            LOCK_PATH.parent.exists() and not LOCK_PATH.parent.is_dir()
        ):
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

    def prepare_fixture(self) -> None:
        if self.skip_prepare or os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
            return
        run(["mise", "run", "e2e:prepare:runc:jcode-stub"])
        run(["mise", "run", "agent:jcode:build"])

    def patch_config(self) -> None:
        if not E2E_CONFIG.is_file():
            raise E2EError(f"missing prepared config: {E2E_CONFIG}")
        if not (OVERTURE / ".git").is_dir():
            raise E2EError("overture fixture is not initialized; run e2e prepare first")
        original = E2E_CONFIG.read_text(encoding="utf-8")
        patched = patch_overture_remote(original, OVERTURE)
        if patched != original:
            E2E_CONFIG.write_text(patched, encoding="utf-8")

    def ensure_database(self) -> None:
        run(["mise", "run", "db-up"], check=False)
        env = manager_env(
            worker_token=self.worker_token,
            db_port=self.db_port,
            config_path=E2E_CONFIG,
        )
        run([shutil.which("mix") or "mix", "ecto.drop"], cwd=SERVER, env=env, check=False)
        run([shutil.which("mix") or "mix", "ecto.create"], cwd=SERVER, env=env, check=False)
        run([shutil.which("mix") or "mix", "ecto.migrate"], cwd=SERVER, env=env)

    def ensure_images(self) -> None:
        # Manager config load validates every runtime image declared in the
        # generated omashiki.e2e.toml, not only the jcode image this job uses.
        run(["mise", "run", "images"])

    def compile_once(self) -> None:
        env = manager_env(
            worker_token=self.worker_token,
            db_port=self.db_port,
            config_path=E2E_CONFIG,
        )
        run([shutil.which("mix") or "mix", "compile"], cwd=SERVER, env=env)

    def start_fake_llm(self) -> None:
        self.fake_llm = start_process(
            "fake-llm",
            [
                "python3",
                str(ROOT / ".scripts/loadtest/fake_llm.py"),
                "--host",
                "127.0.0.1",
                "--port",
                str(FAKE_LLM_PORT),
                "--model",
                "fake-model",
                "--scenario",
                "python-hello",
                "--lat-ms",
                "0",
                "--jitter-pct",
                "0",
            ],
            os.environ.copy(),
            "host-worker-fake-llm.log",
        )
        wait_http(f"http://127.0.0.1:{FAKE_LLM_PORT}/healthz", process=self.fake_llm, timeout=30)

    def start_manager(self) -> None:
        env = manager_env(
            worker_token=self.worker_token,
            db_port=self.db_port,
            config_path=E2E_CONFIG,
        )
        self.manager = start_process(
            "manager",
            [shutil.which("mix") or "mix", "phx.server"],
            env,
            "host-worker-manager.log",
        )
        wait_http(
            f"http://127.0.0.1:{MANAGER_PORT}/api/v1/health",
            process=self.manager,
        )

    def start_worker(self) -> None:
        env = worker_env(worker_token=self.worker_token)
        self.worker = start_process(
            "worker",
            [shutil.which("mix") or "mix", "run", "--no-halt"],
            env,
            "host-worker-worker.log",
        )
        time.sleep(2)
        if self.worker.poll() is not None:
            log_tail = (LOG_DIR / "host-worker-worker.log").read_text(errors="replace")[-4000:]
            raise E2EError(f"worker exited immediately:\n{log_tail}")

    def start_container_watch(self) -> None:
        self.container_watch_stop.clear()
        self.container_watch_seen = []

        def watch() -> None:
            watch_container_creates(
                self.container_watch_stop,
                self.container_watch_seen,
                self.correlation_id,
            )

        self.container_watch_thread = threading.Thread(
            target=watch,
            name="host-worker-container-watch",
            daemon=True,
        )
        self.container_watch_thread.start()

    def stop_container_watch(self) -> None:
        self.container_watch_stop.set()
        if self.container_watch_thread is not None:
            self.container_watch_thread.join(timeout=2)
            self.container_watch_thread = None

    def start_fleet_watch(self) -> None:
        self.fleet_watch_stop.clear()
        self.fleet_seen = []
        self.fleet_watch_thread = threading.Thread(
            target=watch_fleet,
            args=(self.fleet_watch_stop, self.fleet_seen, self.api_token),
            daemon=True,
        )
        self.fleet_watch_thread.start()

    def stop_fleet_watch(self) -> None:
        self.fleet_watch_stop.set()
        if self.fleet_watch_thread is not None:
            self.fleet_watch_thread.join(timeout=6)
            self.fleet_watch_thread = None

    def assert_fleet_reported(self, job_id: str, container_id: str) -> None:
        """The manager learned about the worker's real container from its report."""
        machine_id = worker_env(worker_token=self.worker_token)["OMASHIKI_NODE"]
        deadline = time.monotonic() + FLEET_TIMEOUT_SEC
        while time.monotonic() < deadline:
            for body in list(self.fleet_seen):
                match = fleet_container(body, container_id)
                if match is None:
                    continue
                node, container = match
                problems = fleet_report_problems(node, container, job_id, machine_id=machine_id)
                if problems:
                    raise E2EError(f"fleet report for {container_id} is wrong: {problems}")
                print(
                    f"fleet reported {container['id'][:12]} ({container['state']}) "
                    f"on {node['machine_id']} for job {job_id}",
                    flush=True,
                )
                return
            time.sleep(0.1)
        raise E2EError(
            f"manager fleet never reported container {container_id} for job {job_id}"
        )

    def assert_fleet_cleared(self, container_id: str) -> None:
        """The removed container left the manager's fleet."""
        deadline = time.monotonic() + FLEET_TIMEOUT_SEC
        last: dict = {}
        while time.monotonic() < deadline:
            status, body = api_request("GET", "/api/v1/fleet", token=self.api_token)
            if status == 200:
                last = body
                if fleet_container(body, container_id) is None:
                    print(f"fleet no longer lists {container_id[:12]}", flush=True)
                    return
            time.sleep(0.25)
        raise E2EError(f"removed container {container_id} still in the fleet: {last}")

    def admit_job(self) -> str:
        self.api_token = ensure_api_token()
        request = {
            "schema_version": 1,
            "idempotency_key": "host-worker-e2e-hello",
            "correlation_id": self.correlation_id,
            "repo": "overture",
            "environment": "e2e-jcode",
            "payload": {
                "instruction": INSTRUCTIONS,
                "title": "e2e-hello-world",
            },
            "priority": 0,
        }
        status, body = api_request("POST", "/api/v1/jobs", request, self.api_token)
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
            status, body = api_request(
                "GET",
                f"/api/v1/jobs/{job_id}/result",
                token=self.api_token,
            )
            if status == 200 and body.get("data", {}).get("status") in {
                "succeeded",
                "failed",
                "cancelled",
            }:
                terminal = body.get("data", {})
                if terminal.get("status") != "succeeded":
                    raise E2EError(
                        "job finished before a labelled host container was observed: "
                        f"{terminal}"
                    )
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
        raise E2EError(
            "no labelled Docker container observed on the host while the job ran"
        )

    def wait_for_result(self, job_id: str) -> dict:
        deadline = time.monotonic() + JOB_TIMEOUT_SEC
        last: dict = {}
        while time.monotonic() < deadline:
            status, body = api_request(
                "GET",
                f"/api/v1/jobs/{job_id}/result",
                token=self.api_token,
            )
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
        show = run(
            ["git", "-C", str(OVERTURE), "show", f"{branch}:hello.py"],
            check=False,
        )
        if show.returncode != 0 or "Hello, World!" not in show.stdout:
            raise E2EError(
                f"hello.py missing or wrong on overture remote branch {branch}: "
                f"{show.stdout}{show.stderr}"
            )

    def cleanup(self) -> None:
        stop_process("worker", self.worker)
        stop_process("manager", self.manager)
        stop_process("fake-llm", self.fake_llm)
        self.worker = None
        self.manager = None
        self.fake_llm = None
        remove_labelled_containers()
        self.release_lock()

    def preflight(self) -> None:
        if not shutil.which("docker"):
            raise Blocker("docker is not installed")
        if not docker_available():
            raise Blocker("docker daemon is not reachable")
        if not postgres_available(self.db_port):
            raise Blocker(
                f"postgres is not reachable on port {self.db_port}; run mise run db-up"
            )
        if port_busy(MANAGER_PORT):
            raise Blocker(f"port {MANAGER_PORT} is already in use")
        if port_busy(FAKE_LLM_PORT):
            raise Blocker(f"port {FAKE_LLM_PORT} is already in use (fake LLM)")

    def run(self) -> None:
        self.preflight()
        self.acquire_lock()
        try:
            self.prepare_fixture()
            self.patch_config()
            self.ensure_database()
            self.ensure_images()
            self.compile_once()
            self.start_fake_llm()
            self.start_manager()
            self.start_worker()
            self.start_container_watch()
            time.sleep(0.3)
            remove_labelled_containers()
            job_id = self.admit_job()
            self.start_fleet_watch()
            try:
                containers = self.wait_for_container_proof(job_id)
                print(
                    f"observed {len(containers)} labelled host container(s): "
                    f"{containers}",
                    flush=True,
                )
            finally:
                self.stop_container_watch()
            self.assert_fleet_reported(job_id, containers[0]["id"])
            result = self.wait_for_result(job_id)
            self.assert_hello_on_remote(result)
            self.assert_fleet_cleared(containers[0]["id"])
            print("host-worker E2E passed", flush=True)
        finally:
            self.stop_fleet_watch()
            self.cleanup()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--skip-prepare",
        action="store_true",
        help="skip mise prepare/build (caller already ran them under the e2e lock)",
    )
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
