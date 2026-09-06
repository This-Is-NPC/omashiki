#!/usr/bin/env python3
"""Unit tests for compose-worker E2E helpers."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).with_name("compose_worker_e2e.py")
SPEC = importlib.util.spec_from_file_location("compose_worker_e2e", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".scripts"))
SPEC.loader.exec_module(MODULE)


class ComposeWorkerHelperTests(unittest.TestCase):
    def test_port_constants(self) -> None:
        self.assertEqual(MODULE.MANAGER_PORT, 4013)
        self.assertEqual(MODULE.ENROLL_PORT, 4014)
        self.assertEqual(MODULE.FAKE_LLM_PORT, 8788)

    def test_compose_project_names(self) -> None:
        self.assertEqual(MODULE.MANAGER_PROJECT, "omashiki-e2e-mgr")
        self.assertEqual(MODULE.WORKER_PROJECT, "omashiki-e2e-wrk")

    def test_patch_llm_base_url_rewrites_stub_host(self) -> None:
        source = 'base_url = "http://127.0.0.1:8787/v1"\n'
        patched = MODULE.patch_llm_base_url(source)
        self.assertIn(MODULE.COMPOSE_FAKE_LLM_URL, patched)
        self.assertNotIn("127.0.0.1:8787", patched)

    def test_patch_llm_base_url_migrates_host_docker_internal(self) -> None:
        source = f'base_url = "{MODULE.CONTAINER_LLM_HOST_URL}"\n'
        patched = MODULE.patch_llm_base_url(source)
        self.assertIn(MODULE.COMPOSE_FAKE_LLM_URL, patched)
        self.assertNotIn("host.docker.internal", patched)

    def test_worker_override_volume_uses_identical_host_paths(self) -> None:
        overture = Path("/home/tester/Projects/omashiki/overture")
        host, container = MODULE.worker_override_volume(overture)
        self.assertEqual(host, container)
        self.assertEqual(host, str(overture.resolve()))

    def test_render_worker_override_bind_mount(self) -> None:
        overture = Path("/srv/overture")
        rendered = MODULE.render_worker_override(overture)
        self.assertIn("/srv/overture:/srv/overture", rendered)
        self.assertNotIn(":ro", rendered)

    def test_render_manager_override_mounts_repo_without_docker_sock(self) -> None:
        repo = Path("/srv/omashiki")
        rendered = MODULE.render_manager_override(repo)
        self.assertIn("/srv/omashiki:/config/repo:ro", rendered)
        self.assertIn("OMASHIKI_CONFIG: /config/repo/omashiki.e2e.toml", rendered)
        self.assertIn("fake-llm:", rendered)
        self.assertIn("fake_llm.py", rendered)
        self.assertNotIn("docker.sock", rendered)

    def test_teardown_leftovers_invokes_compose_down(self) -> None:
        calls: list[list[str]] = []

        def fake_run(cmd: list[str], **kwargs: object) -> object:
            calls.append(cmd)
            return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()

        original_run = MODULE.run
        original_stop = MODULE.stop_leftover_harness_fake_llm
        original_cache = MODULE.cleanup_compose_e2e_cache
        original_overture = MODULE.cleanup_overture_fixture
        try:
            MODULE.run = fake_run
            MODULE.stop_leftover_harness_fake_llm = lambda port=MODULE.FAKE_LLM_PORT: None
            MODULE.cleanup_compose_e2e_cache = lambda: None
            MODULE.cleanup_overture_fixture = lambda: None
            MODULE.teardown_leftovers()
        finally:
            MODULE.run = original_run
            MODULE.stop_leftover_harness_fake_llm = original_stop
            MODULE.cleanup_compose_e2e_cache = original_cache
            MODULE.cleanup_overture_fixture = original_overture

        self.assertEqual(len(calls), 2)
        self.assertIn("down", calls[0])
        self.assertIn(MODULE.MANAGER_PROJECT, calls[0])
        self.assertIn("down", calls[1])
        self.assertIn(MODULE.WORKER_PROJECT, calls[1])

    def test_manager_override_volume_uses_identical_repo_paths(self) -> None:
        repo = Path("/home/tester/Projects/omashiki")
        host, container = MODULE.manager_override_volume(repo)
        self.assertEqual(host, str(repo.resolve()))
        self.assertEqual(container, "/config/repo")

    def test_enroll_argv_uses_host_docker_internal_and_omits_allow_localhost(
        self,
    ) -> None:
        argv = MODULE.enroll_argv(
            worker_token="worker-secret",
            enroll_secret="enroll-secret",
        )
        self.assertIn("http://host.docker.internal:4013", argv)
        self.assertIn("http://127.0.0.1:4014", argv)
        self.assertNotIn("--allow-localhost", argv)


    def test_cleanup_overture_fixture_deletes_stale_branches(self) -> None:
        calls: list[list[str]] = []

        def fake_run(cmd: list[str], **kwargs: object) -> object:
            calls.append(cmd)
            return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()

        original_run = MODULE.run
        original_exists = MODULE.OVERTURE.__class__  # noqa: B009
        try:
            MODULE.run = fake_run
            MODULE.cleanup_overture_fixture()
        finally:
            MODULE.run = original_run

        joined = [" ".join(cmd) for cmd in calls]
        self.assertTrue(any("branch -D e2e-hello-world" in cmd for cmd in joined))
        self.assertTrue(any("branch -D e2e-hello-world-run-001" in cmd for cmd in joined))


if __name__ == "__main__":
    unittest.main()
