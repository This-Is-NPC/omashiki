#!/usr/bin/env python3
"""Focused stdlib tests for the E2E SSH-file safety helper."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parent))

from e2e import Blocker, Harness  # noqa: E402


class AtomicLineUpdateTests(unittest.TestCase):
    def setUp(self):
        self.harness = Harness.__new__(Harness)
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "ssh-file"

    def tearDown(self):
        self.directory.cleanup()

    def test_add_preserves_bytes_and_separates_line_without_trailing_newline(self):
        self.path.write_bytes(b"pre-existing")
        os.chmod(self.path, 0o640)

        result = self.harness.atomic_line_update(self.path, add=["temporary"])

        self.assertEqual(result["added"], ["temporary"])
        self.assertEqual(self.path.read_bytes(), b"pre-existing\ntemporary\n")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o640)

    def test_add_preserves_bytes_with_trailing_newline(self):
        self.path.write_bytes(b"pre-existing\n")

        self.harness.atomic_line_update(self.path, add=["temporary"])

        self.assertEqual(self.path.read_bytes(), b"pre-existing\ntemporary\n")

    def test_identical_existing_line_is_not_rewritten(self):
        original = b"pre-existing\ntemporary\n"
        self.path.write_bytes(original)
        os.chmod(self.path, 0o640)

        result = self.harness.atomic_line_update(self.path, add=["temporary"])

        self.assertEqual(result["added"], [])
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o640)

    def test_remove_preserves_unterminated_other_line(self):
        self.path.write_bytes(b"pre-existing\ntemporary")

        result = self.harness.atomic_line_update(self.path, remove=["temporary"])

        self.assertEqual(result["removed"], ["temporary"])
        self.assertEqual(self.path.read_bytes(), b"pre-existing\n")

    def test_symlink_is_rejected(self):
        target = Path(self.directory.name) / "target"
        target.write_bytes(b"unchanged")
        self.path.symlink_to(target)

        with self.assertRaises(Blocker):
            self.harness.atomic_line_update(self.path, add=["temporary"])


class LifecycleSafetyTests(unittest.TestCase):
    def test_stop_started_vms_stops_created_domain_with_absent_initial_state(self):
        harness = Harness.__new__(Harness)
        harness.vm_initial_state = {"omashiki-node-1": None, "omashiki-node-2": None}
        harness.vm_started_by_run = set()
        harness.vm_created_by_run = {"omashiki-node-1"}
        harness.virsh = Mock(side_effect=["running", "shut off"])
        harness.local = Mock()

        self.assertTrue(harness.stop_started_vms())
        harness.local.assert_called_once_with(["virsh", "-c", "qemu:///system", "shutdown", "omashiki-node-1"], check=False)

    def test_stop_started_vms_does_not_touch_unrecorded_preexisting_domain(self):
        harness = Harness.__new__(Harness)
        harness.vm_initial_state = {"omashiki-node-1": "running", "omashiki-node-2": "shut off"}
        harness.vm_started_by_run = set()
        harness.vm_created_by_run = set()
        harness.virsh = Mock()
        harness.local = Mock()

        self.assertTrue(harness.stop_started_vms())
        harness.virsh.assert_not_called()
        harness.local.assert_not_called()

    def test_cleanup_completeness_requires_dynamic_guest_keys(self):
        harness = Harness.__new__(Harness)
        harness.cleanup_errors = []
        harness.remote_pids = {"omashiki-node-1:fake": {}}
        harness.report = {"cleanup": {
            "host_processes_stopped": True,
            "reverse_tunnels_stopped": True,
            "evidence_logs_copied": True,
            "temporary_auth_removed": True,
            "runtime_removed": True,
            "database_removed": True,
            "labelled_containers_absent": True,
            "new_vms_stopped": True,
            "vms_definitions_preserved": True,
            "guest_known_hosts_additions_removed": True,
            "image_removed": {"host": True, "omashiki-node-1": True, "omashiki-node-2": True},
            "selinux": {"all_restored": True},
            "omashiki-node-1_containers_removed": True,
            "omashiki-node-2_containers_removed": True,
            "omashiki-node-1_known_hosts_additions_removed": True,
            "omashiki-node-2_known_hosts_additions_removed": True,
        }}

        self.assertTrue(harness.cleanup_is_complete({"omashiki-node-1:fake": True}))
        harness.report["cleanup"]["omashiki-node-2_containers_removed"] = False
        self.assertFalse(harness.cleanup_is_complete({"omashiki-node-1:fake": True}))

    def test_remote_pid_is_registered_before_metadata_validation(self):
        harness = Harness.__new__(Harness)
        harness.guest_root = Path("/tmp/omashiki-vm-e2e-test-run")
        harness.remote_pids = {}
        harness.report = {"evidence": {}}

        key = harness.register_remote_process("omashiki-node-1", "worker", "1234", "mix phx.server")

        self.assertEqual(key, "omashiki-node-1:worker")
        self.assertEqual(harness.remote_pids[key]["pid"], "1234")
        self.assertEqual(harness.remote_pids[key]["run_root"], "/tmp/omashiki-vm-e2e-test-run")
        self.assertIsNone(harness.remote_pids[key]["pgrp"])

    def test_remote_launch_registers_fallback_when_pid_capture_fails(self):
        harness = Harness.__new__(Harness)
        harness.guest_source = Path("/tmp/omashiki-vm-e2e-test-run/source")
        harness.guest_logs = Path("/tmp/omashiki-vm-e2e-test-run/logs")
        harness.guest_root = Path("/tmp/omashiki-vm-e2e-test-run")
        harness.remote_log_paths = {}
        harness.remote_pids = {}
        harness.report = {"evidence": {}}
        harness.guest_port_free = Mock(return_value=True)
        harness.ssh = Mock(return_value="launch-output-without-a-pid")

        with self.assertRaises(RuntimeError):
            harness.start_remote_process("omashiki-node-1", "fake", {}, "fake.log", 8787)

        self.assertIn("omashiki-node-1:fake", harness.remote_pids)
        self.assertEqual(harness.remote_pids["omashiki-node-1:fake"]["pid"], "")


if __name__ == "__main__":
    unittest.main()
