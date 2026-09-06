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


if __name__ == "__main__":
    unittest.main()
