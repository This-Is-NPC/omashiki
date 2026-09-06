#!/usr/bin/env python3
"""POST manager credentials to a worker enroll listener."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
from ipaddress import ip_address
import urllib.request


class EnrollError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message


def normalize_base_url(url: str) -> str:
    trimmed = url.strip()
    if not trimmed:
        raise ValueError("URL must not be empty")
    return trimmed.rstrip("/")

def is_loopback_manager_url(url: str) -> bool:
    try:
        normalized = normalize_base_url(url)
    except ValueError:
        return False

    host = urllib.parse.urlparse(normalized).hostname
    if not host:
        return False

    if host.lower() == "localhost" or host == "0.0.0.0":
        return True

    try:
        return ip_address(host).is_loopback
    except ValueError:
        return False



def build_enroll_body(manager_url: str, worker_token: str, manager_id: str | None = None) -> bytes:
    token = worker_token.strip()
    if not token:
        raise ValueError("worker_token must not be empty")
    payload = {
        "manager_url": normalize_base_url(manager_url),
        "worker_token": token,
    }
    # One worker serves many houses; the id is how a house is told apart on
    # the worker (mirrors, state, un-enrollment). Defaults to the URL host.
    if manager_id and manager_id.strip():
        payload["manager_id"] = manager_id.strip()
    return json.dumps(payload).encode()


def build_enroll_request(
    worker_url: str,
    enroll_secret: str,
    manager_url: str,
    worker_token: str,
    manager_id: str | None = None,
) -> urllib.request.Request:
    secret = enroll_secret.strip()
    if not secret:
        raise ValueError("enroll_secret must not be empty")

    request = urllib.request.Request(
        f"{normalize_base_url(worker_url)}/internal/enroll",
        data=build_enroll_body(manager_url, worker_token, manager_id),
        method="POST",
    )
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", f"Bearer {secret}")
    return request


def parse_error_body(raw: bytes) -> tuple[str, str]:
    try:
        decoded = json.loads(raw.decode())
    except json.JSONDecodeError:
        return "unknown", raw.decode(errors="replace") or "request failed"

    error = decoded.get("error") or {}
    code = str(error.get("code") or "unknown")
    message = str(error.get("message") or "request failed")
    return code, message


def enroll(
    *,
    worker_url: str,
    enroll_secret: str,
    manager_url: str,
    worker_token: str,
    timeout: float = 30,
    manager_id: str | None = None,
) -> None:
    request = build_enroll_request(worker_url, enroll_secret, manager_url, worker_token, manager_id)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        code, message = parse_error_body(error.read())
        raise EnrollError(error.code, code, message) from error

    if status != 204:
        raise EnrollError(status, "unexpected_status", f"expected 204, got {status}")


def check_health(worker_url: str, timeout: float = 10) -> dict:
    request = urllib.request.Request(
        f"{normalize_base_url(worker_url)}/healthz",
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def wait_for_health(
    worker_url: str,
    *,
    timeout: float = 30,
    interval: float = 0.5,
) -> dict:
    deadline = time.monotonic() + timeout
    last_error: urllib.error.URLError | None = None

    while time.monotonic() < deadline:
        try:
            health = check_health(worker_url, timeout=min(interval, timeout))
            if health.get("role") == "worker" and health.get("status") == "ok":
                return health
            last_error = urllib.error.URLError(
                f"unexpected healthz payload: {health}"
            )
        except urllib.error.URLError as error:
            last_error = error
        time.sleep(interval)

    raise last_error or urllib.error.URLError("timed out waiting for /healthz")


def require_setting(value: str | None, name: str, flag: str) -> str:
    if value is None or not str(value).strip():
        raise SystemExit(
            f"missing {name}: pass {flag} or export {name} (see .env.example)"
        )
    return str(value).strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Enroll a remote Omashiki worker with manager credentials.",
    )
    parser.add_argument(
        "--worker-url",
        default=os.environ.get("OMASHIKI_WORKER_URL"),
        help="Worker enroll listener base URL (default: $OMASHIKI_WORKER_URL)",
    )
    parser.add_argument(
        "--manager-url",
        default=os.environ.get("OMASHIKI_MANAGER_URL"),
        help="Manager HTTP base URL (default: $OMASHIKI_MANAGER_URL)",
    )
    parser.add_argument(
        "--worker-token",
        default=os.environ.get("OMASHIKI_WORKER_TOKEN"),
        help="Shared worker token for /internal/work/* (default: $OMASHIKI_WORKER_TOKEN)",
    )
    parser.add_argument(
        "--enroll-secret",
        default=os.environ.get("OMASHIKI_ENROLL_SECRET"),
        help="Bearer secret for POST /internal/enroll (default: $OMASHIKI_ENROLL_SECRET)",
    )
    parser.add_argument(
        "--manager-id",
        default=os.environ.get("OMASHIKI_MANAGER_ID"),
        help="House id on the worker; enrolling it again replaces it (default: URL host)",
    )
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument(
        "--health-timeout",
        type=float,
        default=30,
        help="Seconds to poll GET /healthz before enrolling (default: 30)",
    )
    parser.add_argument(
        "--skip-health",
        action="store_true",
        help="Skip GET /healthz before enrolling",
    )
    parser.add_argument(
        "--allow-localhost",
        action="store_true",
        help="allow a loopback --manager-url (same-host tests only)",
    )
    args = parser.parse_args(argv)

    worker_url = require_setting(args.worker_url, "OMASHIKI_WORKER_URL", "--worker-url")
    manager_url = require_setting(args.manager_url, "OMASHIKI_MANAGER_URL", "--manager-url")
    worker_token = require_setting(args.worker_token, "OMASHIKI_WORKER_TOKEN", "--worker-token")
    enroll_secret = require_setting(
        args.enroll_secret,
        "OMASHIKI_ENROLL_SECRET",
        "--enroll-secret",
    )

    if is_loopback_manager_url(manager_url) and not args.allow_localhost:
        print(
            "enroll refused: --manager-url is loopback (localhost/127.0.0.1). "
            "The worker (and job containers) must reach the manager; pass a LAN, "
            "Tailscale, public, or host.docker.internal URL. Use --allow-localhost "
            "only for same-host tests.",
            file=sys.stderr,
        )
        return 1

    try:
        if not args.skip_health:
            wait_for_health(worker_url, timeout=args.health_timeout)
        enroll(
            worker_url=worker_url,
            enroll_secret=enroll_secret,
            manager_url=manager_url,
            worker_token=worker_token,
            timeout=args.timeout,
            manager_id=args.manager_id,
        )
    except EnrollError as error:
        print(f"enroll failed: {error}", file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"enroll failed: {error}", file=sys.stderr)
        return 1
    except ValueError as error:
        print(f"enroll failed: {error}", file=sys.stderr)
        return 1


    print("enrolled worker")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
