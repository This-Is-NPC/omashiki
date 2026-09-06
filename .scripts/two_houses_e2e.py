#!/usr/bin/env python3
"""Two houses, one machine: the multi-house isolation E2E.

Starts two manager BEAMs (Ana's house and João's house, each with its own
Postgres database, port, worker token and API token) and one worker BEAM
that is enrolled into both over the enroll listener. Then proves:

  1. a job admitted in each house runs on the same worker and succeeds;
  2. each house sees only its own job: the other house answers 404;
  3. the worker keeps Git mirrors apart per house id;
  4. killing one house does not stop the other, and restarting it brings it
     back on the same worker without re-enrolling.

Everything runs on this machine against the host Docker daemon, like
host_worker_e2e.py, whose helpers this script reuses.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("host_worker_e2e", HERE / "host_worker_e2e.py")
host = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(host)

ROOT = host.ROOT
SERVER = host.SERVER
E2E_CONFIG = host.E2E_CONFIG
OVERTURE = host.OVERTURE
LOG_DIR = host.LOG_DIR
E2EError = host.E2EError
Blocker = host.Blocker
JOB_TIMEOUT_SEC = host.JOB_TIMEOUT_SEC
FAKE_LLM_PORT = host.FAKE_LLM_PORT
ENROLL_PORT = 4023
WORKER_STATE = LOG_DIR / "two-houses-worker-state.json"

HOUSES = {
    "ana": {"port": 4021, "db": "omashiki_house_ana_e2e"},
    "joao": {"port": 4022, "db": "omashiki_house_joao_e2e"},
}


def manager_env(house: str, *, worker_token: str, db_port: int, config_path: Path) -> dict[str, str]:
    """One house's process environment: its own port, database and worker token."""
    spec = HOUSES[house]
    env = os.environ.copy()
    env.update(
        {
            "MIX_ENV": "dev",
            "OMASHIKI_ROLE": "manager",
            "OMASHIKI_NODE": f"house-{house}",
            "OMASHIKI_WORKER_TOKEN": worker_token,
            "OMASHIKI_CONFIG": str(config_path.resolve()),
            "PORT": str(spec["port"]),
            "OMASHIKI_DB_NAME": spec["db"],
            "OMASHIKI_AGENT_NETWORK_MODE": "host",
            "OMASHIKI_DB_PORT": str(db_port),
            # Two houses on one host: each needs its own supply-chain socket.
            # Under Compose every house has its own filesystem and this is moot.
            "OMASHIKI_SUPPLY_CHAIN_SOCKET_PATH": str(LOG_DIR / f"two-houses-{house}-supply.sock"),
        }
    )
    return env


def worker_env(*, enroll_secret: str) -> dict[str, str]:
    """The lent machine: no manager at boot, enrollment does the rest."""
    env = os.environ.copy()
    env.update(
        {
            "MIX_ENV": "dev",
            "OMASHIKI_ROLE": "worker",
            "OMASHIKI_NODE": "worker-1",
            "OMASHIKI_ENROLL_SECRET": enroll_secret,
            "OMASHIKI_ENROLL_PORT": str(ENROLL_PORT),
            "OMASHIKI_WORKER_STATE_PATH": str(WORKER_STATE),
            "OMASHIKI_DOCKER_SOCKET_PATH": "/var/run/docker.sock",
            "OMASHIKI_AGENT_NETWORK_MODE": "host",
            "OMASHIKI_MAX_CONCURRENT_CONTAINERS": "2",
        }
    )
    for key in ("OMASHIKI_CONFIG", "OMASHIKI_MANAGER_URL", "OMASHIKI_WORKER_TOKEN", "OMASHIKI_MANAGERS"):
        env.pop(key, None)
    return env


def mirror_root() -> Path:
    return Path.home() / ".cache" / "omashiki" / "mirrors"


def assert_isolated(houses: dict[str, dict]) -> None:
    """Pure check over what each house reported: no id, branch or mirror shared."""
    ids = [h["job_id"] for h in houses.values()]
    if len(set(ids)) != len(ids):
        raise E2EError(f"houses share a job id: {ids}")
    branches = [h["result"].get("branch") for h in houses.values()]
    if len(set(branches)) != len(branches) or not all(branches):
        raise E2EError(f"houses share a branch or one is missing: {branches}")
    for name, h in houses.items():
        for other, status in h["seen_by_others"].items():
            if status != 404:
                raise E2EError(f"{other} answered {status} for {name}'s job; expected 404")


class Harness:
    def __init__(self, *, skip_prepare: bool = False) -> None:
        self.skip_prepare = skip_prepare
        self.db_port = host.default_db_port()
        self.enroll_secret = secrets.token_urlsafe(24)
        self.tokens = {name: secrets.token_urlsafe(32) for name in HOUSES}
        self.api_tokens: dict[str, str | None] = {}
        self.managers: dict[str, subprocess.Popen | None] = {name: None for name in HOUSES}
        self.worker: subprocess.Popen | None = None
        self.fake_llm: subprocess.Popen | None = None
        self.run_id = secrets.token_hex(3)

    # --- setup -------------------------------------------------------------

    def prepare_fixture(self) -> None:
        if self.skip_prepare or os.environ.get("OMASHIKI_E2E_LOCK_HELD") == "1":
            return
        host.run(["mise", "run", "e2e:prepare:runc:jcode-stub"])
        host.run(["mise", "run", "agent:jcode:build"])
        host.run(["mise", "run", "images"])

    def patch_config(self) -> None:
        if not E2E_CONFIG.is_file():
            raise E2EError(f"missing prepared config: {E2E_CONFIG}")
        original = E2E_CONFIG.read_text(encoding="utf-8")
        patched = host.patch_overture_remote(original, OVERTURE)
        if patched != original:
            E2E_CONFIG.write_text(patched, encoding="utf-8")

    def env_for(self, house: str) -> dict[str, str]:
        return manager_env(house, worker_token=self.tokens[house], db_port=self.db_port, config_path=E2E_CONFIG)

    def ensure_databases(self) -> None:
        host.run(["mise", "run", "db-up"], check=False)
        mix = shutil.which("mix") or "mix"
        for house in HOUSES:
            env = self.env_for(house)
            host.run([mix, "ecto.drop"], cwd=SERVER, env=env, check=False)
            host.run([mix, "ecto.create"], cwd=SERVER, env=env, check=False)
            host.run([mix, "ecto.migrate"], cwd=SERVER, env=env)

    def compile_once(self) -> None:
        host.run([shutil.which("mix") or "mix", "compile"], cwd=SERVER, env=self.env_for("ana"))

    def start_fake_llm(self) -> None:
        self.fake_llm = host.start_process(
            "fake-llm",
            [
                "python3", str(ROOT / ".scripts/loadtest/fake_llm.py"),
                "--host", "127.0.0.1", "--port", str(FAKE_LLM_PORT),
                "--model", "fake-model", "--scenario", "python-hello",
                "--lat-ms", "0", "--jitter-pct", "0",
            ],
            os.environ.copy(),
            "two-houses-fake-llm.log",
        )
        host.wait_http(f"http://127.0.0.1:{FAKE_LLM_PORT}/healthz", process=self.fake_llm, timeout=30)

    def start_manager(self, house: str) -> None:
        self.managers[house] = host.start_process(
            f"manager-{house}",
            [shutil.which("mix") or "mix", "phx.server"],
            self.env_for(house),
            f"two-houses-manager-{house}.log",
        )
        host.wait_http(f"http://127.0.0.1:{HOUSES[house]['port']}/api/v1/health", process=self.managers[house])

    def stop_manager(self, house: str, *, kill: bool = False) -> None:
        process = self.managers[house]
        if process is None:
            return
        if kill and process.poll() is None:
            # SIGKILL the whole session (mix -> erl): a crash, not a drain.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        else:
            host.stop_process(f"manager-{house}", process)
        self.managers[house] = None

    def start_worker(self) -> None:
        WORKER_STATE.unlink(missing_ok=True)
        self.worker = host.start_process(
            "worker",
            [shutil.which("mix") or "mix", "run", "--no-halt"],
            worker_env(enroll_secret=self.enroll_secret),
            "two-houses-worker.log",
        )
        host.wait_http(f"http://127.0.0.1:{ENROLL_PORT}/healthz", process=self.worker, timeout=120)

    def enroll(self, house: str) -> None:
        result = host.run(
            [
                "python3", str(HERE / "enroll_worker.py"),
                "--worker-url", f"http://127.0.0.1:{ENROLL_PORT}",
                "--manager-url", f"http://127.0.0.1:{HOUSES[house]['port']}",
                "--manager-id", f"house-{house}",
                "--worker-token", self.tokens[house],
                "--enroll-secret", self.enroll_secret,
                "--allow-localhost",
            ],
            check=False,
        )
        if result.returncode != 0:
            raise E2EError(f"enroll into {house} failed: {result.stdout}{result.stderr}")

    def enrolled_ids(self) -> list[str]:
        import urllib.request

        request = urllib.request.Request(f"http://127.0.0.1:{ENROLL_PORT}/internal/enroll")
        request.add_header("Authorization", f"Bearer {self.enroll_secret}")
        with urllib.request.urlopen(request, timeout=10) as response:
            return [m["id"] for m in json.loads(response.read())["managers"]]

    # --- one job in one house ---------------------------------------------

    def api(self, house: str, method: str, path: str, payload: dict | None = None, token: str | None = None):
        return host.api_request(method, path, payload, token, port=HOUSES[house]["port"])

    def api_token(self, house: str) -> str | None:
        """Each house issues its own API token; none is valid in the other."""
        if house not in self.api_tokens:
            status, _ = self.api(house, "POST", "/api/v1/jobs", {"schema_version": 1})
            if status == 401:
                username = f"{house}_{self.run_id}"
                signup_status, body = self.api(
                    house,
                    "POST",
                    "/api/v1/sessions/signup",
                    {
                        "email": f"{username}@example.test",
                        "username": username,
                        "password": secrets.token_urlsafe(24),
                        "name": f"House {house}",
                    },
                )
                token = (body.get("data") or {}).get("token")
                if signup_status != 201 or not token:
                    raise E2EError(f"{house}: signup failed with HTTP {signup_status}: {body}")
                self.api_tokens[house] = token
            elif status in (400, 422):
                self.api_tokens[house] = None
            else:
                raise E2EError(f"{house}: unexpected probe response HTTP {status}")
        return self.api_tokens[house]

    def admit(self, house: str, tag: str) -> str:
        request = {
            "schema_version": 1,
            "idempotency_key": f"two-houses-{self.run_id}-{house}-{tag}",
            "correlation_id": f"two-houses-{self.run_id}-{house}-{tag}",
            "repo": "overture",
            "environment": "e2e-jcode",
            "payload": {"instruction": host.INSTRUCTIONS, "title": f"{house}-{tag}-{self.run_id}"},
            "priority": 0,
        }
        status, body = self.api(house, "POST", "/api/v1/jobs", request, self.api_token(house))
        if status != 202:
            raise E2EError(f"{house}: admission failed with HTTP {status}: {body}")
        return body["data"]["id"]

    def wait_result(self, house: str, job_id: str) -> dict:
        deadline = time.monotonic() + JOB_TIMEOUT_SEC
        last: dict = {}
        while time.monotonic() < deadline:
            status, body = self.api(house, "GET", f"/api/v1/jobs/{job_id}/result", token=self.api_token(house))
            if status == 200:
                last = body.get("data", {})
                if last.get("status") == "succeeded":
                    return last
                if last.get("status") in {"failed", "cancelled"}:
                    raise E2EError(f"{house}: job {job_id} ended {last.get('status')}: {last}")
            time.sleep(1)
        raise E2EError(f"{house}: timed out waiting for job {job_id}: {last}")

    def seen_by(self, house: str, job_id: str) -> int:
        status, _ = self.api(house, "GET", f"/api/v1/jobs/{job_id}", token=self.api_token(house))
        return status

    def assert_branch_on_remote(self, result: dict) -> None:
        branch = result.get("branch")
        show = host.run(["git", "-C", str(OVERTURE), "show", f"{branch}:hello.py"], check=False)
        if show.returncode != 0 or "Hello, World!" not in show.stdout:
            raise E2EError(f"hello.py missing on overture branch {branch}: {show.stdout}{show.stderr}")

    # --- the proof -----------------------------------------------------------

    def run_both_in_parallel(self) -> None:
        jobs = {house: self.admit(house, "first") for house in HOUSES}
        report: dict[str, dict] = {}
        for house, job_id in jobs.items():
            result = self.wait_result(house, job_id)
            self.assert_branch_on_remote(result)
            report[house] = {
                "job_id": job_id,
                "result": result,
                "seen_by_others": {other: self.seen_by(other, job_id) for other in HOUSES if other != house},
            }
        assert_isolated(report)
        for house in HOUSES:
            segment = mirror_root() / f"house-{house}"
            if not segment.is_dir():
                raise E2EError(f"no mirror segment for house-{house} under {mirror_root()}")
        print(f"both houses completed on one worker, isolated: {json.dumps({h: r['job_id'] for h, r in report.items()})}", flush=True)

    def run_kill_and_restart(self) -> None:
        self.stop_manager("ana", kill=True)
        print("killed house-ana", flush=True)
        job = self.admit("joao", "while-ana-down")
        self.wait_result("joao", job)
        print("house-joao kept working while house-ana was down", flush=True)

        self.start_manager("ana")
        if self.enrolled_ids() != ["house-ana", "house-joao"]:
            raise E2EError(f"enrollment changed across restart: {self.enrolled_ids()}")
        job = self.admit("ana", "after-restart")
        self.wait_result("ana", job)
        print("house-ana came back on the same worker without re-enrolling", flush=True)

    def cleanup(self) -> None:
        host.stop_process("worker", self.worker)
        for house in HOUSES:
            self.stop_manager(house)
        host.stop_process("fake-llm", self.fake_llm)
        self.worker = None
        self.fake_llm = None
        host.remove_labelled_containers()
        WORKER_STATE.unlink(missing_ok=True)

    def preflight(self) -> None:
        if not shutil.which("docker"):
            raise Blocker("docker is not installed")
        if not host.docker_available():
            raise Blocker("docker daemon is not reachable")
        if not host.postgres_available(self.db_port):
            raise Blocker(f"postgres is not reachable on port {self.db_port}; run mise run db-up")
        for port in [spec["port"] for spec in HOUSES.values()] + [ENROLL_PORT, FAKE_LLM_PORT]:
            if host.port_busy(port):
                raise Blocker(f"port {port} is already in use")

    def run(self) -> None:
        self.preflight()
        try:
            self.prepare_fixture()
            self.patch_config()
            self.ensure_databases()
            self.compile_once()
            self.start_fake_llm()
            for house in HOUSES:
                self.start_manager(house)
            self.start_worker()
            for house in HOUSES:
                self.enroll(house)
            if self.enrolled_ids() != ["house-ana", "house-joao"]:
                raise E2EError(f"unexpected enrollment: {self.enrolled_ids()}")
            host.remove_labelled_containers()
            self.run_both_in_parallel()
            self.run_kill_and_restart()
            print("two-houses E2E passed", flush=True)
        finally:
            self.cleanup()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-prepare", action="store_true", help="caller already ran prepare/images under the e2e lock")
    args = parser.parse_args(argv)
    try:
        Harness(skip_prepare=args.skip_prepare).run()
    except Blocker as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    except E2EError as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
