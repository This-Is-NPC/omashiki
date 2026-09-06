#!/usr/bin/env python3
"""Unit tests for enroll_worker.py helpers."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest
import urllib.error
from unittest import mock

SCRIPT = Path(__file__).with_name("enroll_worker.py")
SPEC = importlib.util.spec_from_file_location("enroll_worker", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class EnrollWorkerHelperTests(unittest.TestCase):
    def test_normalize_base_url_strips_trailing_slash(self) -> None:
        self.assertEqual(
            MODULE.normalize_base_url("http://worker.test:4012/"),
            "http://worker.test:4012",
        )

    def test_normalize_base_url_rejects_empty(self) -> None:
        with self.assertRaises(ValueError):
            MODULE.normalize_base_url("   ")

    def test_build_enroll_body_encodes_credentials(self) -> None:
        body = MODULE.build_enroll_body(
            "http://manager.test:4010/",
            "worker-token",
        )
        self.assertEqual(
            json.loads(body.decode()),
            {
                "manager_url": "http://manager.test:4010",
                "worker_token": "worker-token",
            },
        )

    def test_build_enroll_request_sets_bearer_and_path(self) -> None:
        request = MODULE.build_enroll_request(
            "http://worker.test:4012",
            "enroll-secret",
            "http://manager.test:4010",
            "worker-token",
        )

        self.assertEqual(request.full_url, "http://worker.test:4012/internal/enroll")
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer enroll-secret")
        self.assertEqual(
            json.loads(request.data.decode()),
            {
                "manager_url": "http://manager.test:4010",
                "worker_token": "worker-token",
            },
        )

    def test_parse_error_body_reads_contract_code(self) -> None:
        raw = json.dumps(
            {"error": {"code": "invalid_body", "message": "manager_url and worker_token are required"}}
        ).encode()

        self.assertEqual(
            MODULE.parse_error_body(raw),
            ("invalid_body", "manager_url and worker_token are required"),
        )

    def test_wait_for_health_retries_until_ok(self) -> None:
        health = {"role": "worker", "status": "ok"}
        with mock.patch.object(MODULE, "check_health", side_effect=[health]) as check:
            self.assertEqual(
                MODULE.wait_for_health("http://worker.test:4012", timeout=1),
                health,
            )
        check.assert_called_once()

    def test_wait_for_health_raises_after_timeout(self) -> None:
        with mock.patch.object(
            MODULE,
            "check_health",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            with self.assertRaises(urllib.error.URLError):
                MODULE.wait_for_health("http://worker.test:4012", timeout=0.2, interval=0.05)

    def test_enroll_raises_enroll_error_on_http_failure(self) -> None:
        urllib_error = __import__("urllib.error").error
        error = urllib_error.HTTPError(
            url="http://worker.test/internal/enroll",
            code=403,
            msg="Forbidden",
            hdrs=mock.Mock(),
            fp=mock.Mock(
                read=mock.Mock(
                    return_value=json.dumps(
                        {
                            "error": {
                                "code": "invalid_token",
                                "message": "Enroll bearer token is not valid",
                            }
                        }
                    ).encode()
                )
            ),
        )

        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(MODULE.EnrollError) as raised:
                MODULE.enroll(
                    worker_url="http://worker.test:4012",
                    enroll_secret="secret",
                    manager_url="http://manager.test:4010",
                    worker_token="worker-token",
                )

        self.assertEqual(raised.exception.status, 403)
        self.assertEqual(raised.exception.code, "invalid_token")

    def test_enroll_succeeds_on_204(self) -> None:
        response = mock.Mock(status=204)
        response.__enter__ = mock.Mock(return_value=response)
        response.__exit__ = mock.Mock(return_value=False)

        with mock.patch.object(MODULE.urllib.request, "urlopen", return_value=response):
            MODULE.enroll(
                worker_url="http://worker.test:4012",
                enroll_secret="secret",
                manager_url="http://manager.test:4010",
                worker_token="worker-token",
            )

    def test_main_requires_worker_url(self) -> None:
        with mock.patch.object(MODULE, "enroll") as enroll:
            with self.assertRaises(SystemExit):
                MODULE.main(
                    [
                        "--manager-url",
                        "http://manager.test:4010",
                        "--worker-token",
                        "tok",
                        "--enroll-secret",
                        "secret",
                        "--skip-health",
                    ]
                )

        enroll.assert_not_called()

    def test_is_loopback_manager_url_detects_loopback_hosts(self) -> None:
        loopback_urls = [
            "http://127.0.0.1:4010",
            "http://localhost:4010/",
            "http://127.2.3.4:9",
            "http://[::1]:4010",
            "http://0.0.0.0:4010",
        ]
        for url in loopback_urls:
            with self.subTest(url=url):
                self.assertTrue(MODULE.is_loopback_manager_url(url))

    def test_is_loopback_manager_url_rejects_reachable_hosts(self) -> None:
        reachable_urls = [
            "http://host.docker.internal:4010",
            "http://10.0.0.5:4010",
            "http://100.64.1.2:4010",
        ]
        for url in reachable_urls:
            with self.subTest(url=url):
                self.assertFalse(MODULE.is_loopback_manager_url(url))

    def _main_args(self, manager_url: str, *, allow_localhost: bool = False) -> list[str]:
        args = [
            "--worker-url",
            "http://worker.test:4012",
            "--manager-url",
            manager_url,
            "--worker-token",
            "tok",
            "--enroll-secret",
            "secret",
            "--skip-health",
        ]
        if allow_localhost:
            args.append("--allow-localhost")
        return args

    def test_main_refuses_loopback_manager_url_without_flag(self) -> None:
        loopback_urls = [
            "http://127.0.0.1:4010",
            "http://localhost:4010",
            "http://[::1]:4010",
        ]
        for manager_url in loopback_urls:
            with self.subTest(manager_url=manager_url):
                with mock.patch.object(MODULE, "enroll") as enroll:
                    with mock.patch.object(MODULE, "wait_for_health") as wait_for_health:
                        result = MODULE.main(self._main_args(manager_url))

                self.assertEqual(result, 1)
                enroll.assert_not_called()
                wait_for_health.assert_not_called()

    def test_main_allows_loopback_manager_url_with_flag(self) -> None:
        loopback_urls = [
            "http://127.0.0.1:4010",
            "http://localhost:4010",
            "http://[::1]:4010",
        ]
        for manager_url in loopback_urls:
            with self.subTest(manager_url=manager_url):
                with mock.patch.object(MODULE, "enroll") as enroll:
                    result = MODULE.main(
                        self._main_args(manager_url, allow_localhost=True)
                    )

                self.assertEqual(result, 0)
                enroll.assert_called_once()

    def test_main_allows_host_docker_internal_without_flag(self) -> None:
        with mock.patch.object(MODULE, "enroll") as enroll:
            result = MODULE.main(
                self._main_args("http://host.docker.internal:4010")
            )

        self.assertEqual(result, 0)
        enroll.assert_called_once()



if __name__ == "__main__":
    unittest.main()
