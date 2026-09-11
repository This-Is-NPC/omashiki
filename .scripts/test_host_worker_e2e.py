#!/usr/bin/env python3
"""Unit tests for host-worker E2E helpers."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("host_worker_e2e.py")
SPEC = importlib.util.spec_from_file_location("host_worker_e2e", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class HostWorkerHelperTests(unittest.TestCase):
    def test_patch_overture_remote_adds_file_remote(self) -> None:
        source = "[repositories.overture]\npath = \"overture\"\nbase_branch = \"main\"\n"
        overture = Path("/tmp/overture-fixture")

        patched = MODULE.patch_overture_remote(source, overture)

        self.assertIn('remote = "file:///tmp/overture-fixture"', patched)
        self.assertIn('path = "overture"', patched)

    def test_patch_overture_remote_replaces_existing_remote(self) -> None:
        source = (
            "[repositories.overture]\n"
            'path = "overture"\n'
            'remote = "file:///old/path"\n'
            'base_branch = "main"\n'
        )
        overture = Path("/srv/overture")

        patched = MODULE.patch_overture_remote(source, overture)

        self.assertIn('remote = "file:///srv/overture"', patched)
        self.assertNotIn("file:///old/path", patched)

    def test_manager_env_sets_dedicated_port_and_db(self) -> None:
        env = MODULE.manager_env(
            worker_token="secret-token",
            db_port=5442,
            config_path=Path("/repo/omashiki.e2e.toml"),
        )

        self.assertEqual(env["PORT"], "4011")
        self.assertEqual(env["OMASHIKI_DB_NAME"], "omashiki_host_e2e")
        self.assertEqual(env["OMASHIKI_ROLE"], "manager")
        self.assertEqual(env["OMASHIKI_WORKER_TOKEN"], "secret-token")
        self.assertEqual(env["OMASHIKI_CONFIG"], "/repo/omashiki.e2e.toml")

    def test_worker_env_omits_config_and_sets_docker(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"OMASHIKI_CONFIG": "/should/be/removed"},
            clear=False,
        ):
            env = MODULE.worker_env(worker_token="secret-token")

        self.assertNotIn("OMASHIKI_CONFIG", env)
        self.assertEqual(env["OMASHIKI_ROLE"], "worker")
        self.assertEqual(env["OMASHIKI_DOCKER_SOCKET_PATH"], "/var/run/docker.sock")
        self.assertEqual(env["OMASHIKI_MAX_CONCURRENT_CONTAINERS"], "1")
        self.assertEqual(env["OMASHIKI_MANAGER_URL"], "http://127.0.0.1:4011")

    def fleet(self, container_id: str = "fc0257f99b3df3c283d7f941ce522a54") -> dict:
        return {
            "data": [
                {
                    "machine_id": "worker-1",
                    "kind": "worker",
                    "stale": False,
                    "capacity": 1,
                    "free_slots": 0,
                    "containers": [
                        {"id": container_id, "state": "running", "job_id": "job-1"}
                    ],
                }
            ]
        }

    def test_fleet_container_matches_short_and_full_docker_ids(self) -> None:
        full = "fc0257f99b3df3c283d7f941ce522a54"

        self.assertIsNotNone(MODULE.fleet_container(self.fleet(full), "fc0257f99b3d"))
        self.assertIsNotNone(MODULE.fleet_container(self.fleet("fc0257f99b3d"), full))
        self.assertIsNone(MODULE.fleet_container(self.fleet(full), "aaaaaaaaaaaa"))
        self.assertIsNone(MODULE.fleet_container({"data": []}, full))

    def test_fleet_report_problems_accepts_the_running_worker(self) -> None:
        node, container = MODULE.fleet_container(self.fleet(), "fc0257f99b3d")

        self.assertEqual(
            MODULE.fleet_report_problems(node, container, "job-1", machine_id="worker-1"), []
        )

    def test_fleet_report_problems_names_each_mismatch(self) -> None:
        node, container = MODULE.fleet_container(self.fleet(), "fc0257f99b3d")
        node = {**node, "stale": True, "capacity": 2, "machine_id": "worker-9"}
        container = {**container, "job_id": None, "state": "exploded"}

        problems = MODULE.fleet_report_problems(node, container, "job-1", machine_id="worker-1")

        self.assertEqual(len(problems), 5)


if __name__ == "__main__":
    unittest.main()
