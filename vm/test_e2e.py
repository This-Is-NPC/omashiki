#!/usr/bin/env python3
"""Focused stdlib tests for E2E lifecycle and safety helpers."""

from __future__ import annotations

from contextlib import redirect_stderr
import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import unittest
from unittest.mock import call, Mock, patch

sys.path.insert(0, str(Path(__file__).parent))

from e2e import Blocker, E2EError, Harness, load_manifest, parse_args, validate_manifest  # noqa: E402


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

    def test_snapshot_without_line_preserves_other_bytes(self):
        snapshot = {"exists": True, "mode": 0o600, "bytes": ""}
        import base64
        snapshot["bytes"] = base64.b64encode(b"keep\nremove\n").decode()

        result = self.harness.snapshot_without_line(snapshot, "remove")

        self.assertEqual(base64.b64decode(result["bytes"]), b"keep\n")

    def test_repository_path_rejects_parent_escape(self):
        from e2e import _repository_path

        with self.assertRaises(Blocker):
            _repository_path("../outside", "test path")


class LifecycleSafetyTests(unittest.TestCase):
    def domain_xml(self, extra_device=""):
        return f"""<domain>
          <name>omashiki-node-1</name><title>project=omashiki;purpose=vm-e2e</title>
          <memory unit='KiB'>8388608</memory><currentMemory unit='KiB'>8388608</currentMemory>
          <vcpu placement='static'>4</vcpu><cpu mode='host-passthrough'/>
          <devices>
            <emulator>/usr/bin/qemu-system-x86_64</emulator>
            <disk device='disk'><driver name='qemu' type='qcow2'/><source file='/var/lib/libvirt/images/omashiki-node-1.qcow2'/><target dev='vda' bus='virtio'/></disk>
            <disk device='cdrom'><driver name='qemu' type='raw'/><source file='/var/lib/libvirt/boot/virtinst-test-cloudinit.iso'/><target dev='hda' bus='ide'/><readonly/></disk>
            <controller type='usb'/><controller type='pci'/><controller type='ide'/>
            <interface><source network='default'/><model type='virtio'/></interface>
            <serial><target type='isa-serial'/></serial><console><target type='serial'/></console>
            <input type='mouse' bus='ps2'/><input type='keyboard' bus='ps2'/>
            <audio type='none'/><memballoon model='virtio'/>{extra_device}
          </devices>
        </domain>"""

    def test_missing_volume_query_is_not_present(self):
        harness = Harness.__new__(Harness)

        self.assertTrue(harness.volume_query_is_missing("error: Storage volume not found"))
        self.assertFalse(harness.volume_query_is_present("error: Storage volume not found"))
        self.assertTrue(harness.volume_query_is_present("Name: omashiki-node-1.qcow2"))

    def test_keep_vms_is_opt_in_per_invocation(self):
        self.assertFalse(parse_args([]).keep_vms)
        self.assertTrue(parse_args(["--keep-vms"]).keep_vms)

    def test_runtime_override_is_validated_by_argparse(self):
        self.assertIsNone(parse_args([]).runtime)
        self.assertEqual(parse_args(["--runtime", "kata"]).runtime, "kata")
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parse_args(["--runtime", "other"])

    def test_phase_emits_heartbeat_and_completion(self):
        harness = Harness.__new__(Harness)
        harness.heartbeat_interval_seconds = 0.01
        output = io.StringIO()

        with redirect_stderr(output):
            value = harness.run_phase("slow test phase", lambda: (time.sleep(0.03), "result")[1])

        self.assertEqual(value, "result")
        self.assertIn("==> slow test phase", output.getvalue())
        self.assertIn("... slow test phase", output.getvalue())
        self.assertIn("<== slow test phase complete", output.getvalue())

    def test_cleanup_commands_receive_a_bounded_timeout(self):
        harness = Harness.__new__(Harness)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness.logs = Path(directory.name)
        harness.in_cleanup = True

        with patch("e2e.subprocess.run", return_value=Mock(returncode=0, stdout=b"")) as run:
            harness.local(["true"])

        self.assertEqual(run.call_args.kwargs["timeout"], 15)

    def test_runtime_cloud_init_has_no_package_bootstrap(self):
        template = (Path(__file__).parent / "cloud-init.yaml").read_text()

        self.assertIn("{{HOSTNAME}}", template)
        self.assertIn("{{SSH_PUBLIC_KEY}}", template)
        self.assertNotIn("package_update:", template)
        self.assertNotIn("packages:", template)
        self.assertNotIn("runcmd:", template)

    def test_ssh_keepalive_tolerates_transient_guest_saturation(self):
        harness = Harness.__new__(Harness)
        harness.state = Path("/tmp/run-state")
        harness.vm_user = "fedora"

        args = harness.ssh_args("192.0.2.10")

        self.assertIn("ConnectTimeout=15", args)
        self.assertIn("ServerAliveInterval=10", args)
        self.assertIn("ServerAliveCountMax=6", args)

    def test_kata_worker_uses_bridge_instead_of_host_networking(self):
        harness = Harness.__new__(Harness)
        harness.runtime_variant = "kata"
        self.assertEqual(harness.worker_network_mode(), "bridge")
        harness.runtime_variant = "runc"
        self.assertEqual(harness.worker_network_mode(), "host")

    def test_guest_docker_readiness_accepts_healthy_first_probe(self):
        harness = Harness.__new__(Harness)
        harness.ssh_result = Mock(return_value=Mock(returncode=0))

        self.assertTrue(harness.wait_guest_docker("omashiki-node-1"))
        harness.ssh_result.assert_called_once_with(
            "omashiki-node-1",
            "timeout 10s sudo -n docker info >/dev/null 2>&1",
            check=False,
        )

    def kata_cache_harness(self, directory: str, content: bytes) -> Harness:
        harness = Harness.__new__(Harness)
        harness.runtime_variant = "kata"
        harness.kata_cache_dir = Path(directory) / "omashiki" / "vm-e2e"
        harness.kata_archive_name = "kata.tar.zst"
        harness.kata_bundle = harness.kata_cache_dir / harness.kata_archive_name
        harness.kata_archive_url = "https://example.test/kata.tar.zst"
        import hashlib
        harness.kata_archive_sha256 = hashlib.sha256(content).hexdigest()
        harness.report = {"evidence": {}}
        harness.logs = Path(directory) / "logs"
        return harness

    def test_kata_bundle_reuses_valid_private_cache(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        content = b"validated kata bundle"
        harness = self.kata_cache_harness(directory.name, content)
        harness.kata_cache_dir.mkdir(parents=True, mode=0o700)
        harness.kata_bundle.write_bytes(content)
        os.chmod(harness.kata_bundle, 0o600)
        harness.local = Mock()

        with patch("e2e.Path.is_char_device", return_value=True), patch("e2e.os.access", return_value=True):
            harness.prepare_kata_bundle()

        harness.local.assert_not_called()
        self.assertEqual(harness.report["evidence"]["kata"]["source"], "cache")

    def test_kata_bundle_download_is_published_after_checksum(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        content = b"new kata bundle"
        harness = self.kata_cache_harness(directory.name, content)

        def download(args, **_kwargs):
            Path(args[args.index("--output") + 1]).write_bytes(content)
            return Mock(returncode=0, stdout=b"")

        harness.local = Mock(side_effect=download)
        with patch("e2e.Path.is_char_device", return_value=True), patch("e2e.os.access", return_value=True):
            harness.prepare_kata_bundle()

        self.assertEqual(harness.kata_bundle.read_bytes(), content)
        self.assertEqual(stat.S_IMODE(harness.kata_bundle.stat().st_mode), 0o600)
        self.assertEqual(harness.report["evidence"]["kata"]["source"], "network")

    def test_kata_bundle_rejects_symlinked_cache_archive(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        content = b"kata bundle"
        harness = self.kata_cache_harness(directory.name, content)
        harness.kata_cache_dir.mkdir(parents=True, mode=0o700)
        target = Path(directory.name) / "target"
        target.write_bytes(content)
        harness.kata_bundle.symlink_to(target)

        with patch("e2e.Path.is_char_device", return_value=True), patch("e2e.os.access", return_value=True):
            with self.assertRaises(Blocker):
                harness.prepare_kata_bundle()

    def test_render_config_emits_runtime_catalog_and_dynamic_jcode_image(self):
        harness = Harness.__new__(Harness)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness.source = Path(directory.name) / "source"
        harness.source.mkdir()
        harness.runtime = Path(directory.name) / "runtime"
        harness.image = "omashiki/agent-jcode:vm-e2e-test"
        manifest = load_manifest(Path(__file__).parent / "manifest.toml")
        harness.core_port = 4010
        harness.database_internal_port = 5432
        harness.max_concurrent_containers = 2
        harness.cpu_per_container = 0.25
        harness.memory_per_container = "128MB"
        harness.pids_limit = 128
        harness.runtime_name = "docker.runc.debian"
        harness.runtime_backend = "docker"
        harness.runtime_distribution = "debian"
        harness.runtime_variant = "runc"
        harness.node_names = ("node-1", "node-2")
        harness.artifact_image_key = "jcode"
        harness.project_slug = "omashiki"
        harness.purpose = "vm-e2e"
        harness.ownership_marker = "project=omashiki;purpose=vm-e2e"
        harness.run_id = "20260828-000000-abcdef"
        harness.job_timeout_ms = 180000
        harness.fake_provider_port = 8787
        harness.repository_name = "fixture"
        harness.environment_name = "lt-jcode"
        harness.cpu_per_container = manifest["resources"]["cpu_per_container"]

        harness.render_config("192.0.2.1")

        config = (harness.source / "omashiki.toml").read_text()
        self.assertIn('[runtimes.docker.runc.debian.images]', config)
        self.assertIn('jcode = "omashiki/agent-jcode:vm-e2e-test"', config)
        self.assertEqual(config.count('runtime = "docker.runc.debian"'), 1)
        self.assertIn('host = "127.0.0.1"', config)
        self.assertIn('network = "host"', config)
        self.assertNotIn("isolation =", config)
        self.assertNotIn("image =", config)

        harness.runtime_variant = "kata"
        harness.runtime_name = "docker.kata.debian"
        harness.render_config("192.0.2.1")
        kata_config = (harness.source / "omashiki.toml").read_text()
        self.assertIn('host = "0.0.0.0"', kata_config)
        self.assertIn('network = "restricted"', kata_config)

    def test_manifest_requires_both_runtime_ids(self):
        manifest = load_manifest(Path(__file__).parent / "manifest.toml")
        del manifest["runtime"]["kata_id"]

        with self.assertRaises(Blocker):
            validate_manifest(manifest, Path("manifest.toml"))

    def test_manifest_excludes_server_test_tmp(self):
        manifest = load_manifest(Path(__file__).parent / "manifest.toml")

        self.assertIn("server/tmp", manifest["artifact"]["source_excludes"])
        validate_manifest(manifest, Path("manifest.toml"))

    def test_expected_domain_xml_rejects_unexpected_host_device(self):
        harness = Harness.__new__(Harness)
        harness.runtime_variant = "runc"
        harness.vm_memory_mib = 8192
        harness.vm_vcpus = 4
        harness.volume_owned = Mock(return_value=True)
        xml = self.domain_xml("<hostdev><source><char>/dev/kvm</char></source></hostdev>")

        self.assertFalse(harness.expected_domain_xml(
            "omashiki-node-1", xml, "", "/var/lib/libvirt/images/fedora44-base.qcow2"
        ))

    def test_expected_domain_xml_accepts_virt_install_devices(self):
        harness = Harness.__new__(Harness)
        harness.runtime_variant = "runc"
        harness.vm_memory_mib = 8192
        harness.vm_vcpus = 4
        harness.volume_owned = Mock(return_value=True)

        self.assertTrue(harness.expected_domain_xml(
            "omashiki-node-1",
            self.domain_xml(),
            "<volume/>",
            "/var/lib/libvirt/images/fedora44-base.qcow2",
        ))

    def test_expected_domain_xml_accepts_kata_without_host_device(self):
        harness = Harness.__new__(Harness)
        harness.runtime_variant = "kata"
        harness.vm_memory_mib = 8192
        harness.vm_vcpus = 4
        harness.volume_owned = Mock(return_value=True)

        self.assertTrue(harness.expected_domain_xml(
            "omashiki-node-1",
            self.domain_xml(),
            "<volume/>",
            "/var/lib/libvirt/images/fedora44-base.qcow2",
        ))

    def test_remote_file_restore_does_not_reconnect_after_key_removal(self):
        harness = Harness.__new__(Harness)
        harness.ssh = Mock(return_value="restored")
        harness.remote_file_snapshot = Mock()

        self.assertTrue(harness.remote_file_restore(
            "omashiki-node-1",
            "/home/fedora/.ssh/authorized_keys",
            {"exists": False},
        ))
        harness.remote_file_snapshot.assert_not_called()

    def test_stop_owned_vms_stops_created_domain(self):
        harness = Harness.__new__(Harness)
        harness.vm_owned_by_harness = set()
        harness.vm_created_by_run = {"omashiki-node-1"}
        harness.virsh = Mock(side_effect=["omashiki-node-1", "running", "omashiki-node-1", "shut off"])
        harness.local = Mock(return_value=Mock(returncode=0))
        harness.domain_snapshot = Mock(return_value={"domain_xml": "<domain/>", "volume": {"xml": "<volume/>"}})
        harness.expected_domain_xml = Mock(return_value=True)

        self.assertTrue(harness.stop_owned_vms())
        harness.local.assert_called_once_with(["virsh", "-c", "qemu:///system", "shutdown", "omashiki-node-1"], check=False)

    def test_stop_owned_vms_does_not_touch_unrecorded_domain(self):
        harness = Harness.__new__(Harness)
        harness.vm_owned_by_harness = set()
        harness.vm_created_by_run = set()
        harness.virsh = Mock()
        harness.local = Mock()

        self.assertTrue(harness.stop_owned_vms())
        harness.virsh.assert_not_called()
        harness.local.assert_not_called()

    def test_stop_owned_vms_does_not_destroy_after_shutdown_failure(self):
        harness = Harness.__new__(Harness)
        harness.vm_owned_by_harness = {"omashiki-node-1"}
        harness.vm_created_by_run = set()
        harness.virsh = Mock(side_effect=["omashiki-node-1", "running"])
        harness.domain_snapshot = Mock(return_value={"domain_xml": "<domain/>", "volume": {"xml": "<volume/>"}})
        harness.expected_domain_xml = Mock(return_value=True)
        harness.local = Mock(return_value=Mock(returncode=1))

        self.assertFalse(harness.stop_owned_vms())
        harness.local.assert_called_once_with(
            ["virsh", "-c", "qemu:///system", "shutdown", "omashiki-node-1"], check=False
        )

    def test_stop_owned_vms_destroys_non_shutdown_state(self):
        harness = Harness.__new__(Harness)
        harness.vm_owned_by_harness = {"omashiki-node-1"}
        harness.vm_created_by_run = set()
        harness.virsh = Mock(side_effect=[
            "omashiki-node-1", "paused", "omashiki-node-1", "shut off",
        ])
        harness.local = Mock(return_value=Mock(returncode=0))
        harness.domain_snapshot = Mock(return_value={"domain_xml": "<domain/>", "volume": {"xml": "<volume/>"}})
        harness.expected_domain_xml = Mock(return_value=True)

        self.assertTrue(harness.stop_owned_vms())
        harness.local.assert_called_once_with(
            ["virsh", "-c", "qemu:///system", "destroy", "omashiki-node-1"],
            check=False,
        )

    def test_remove_owned_vms_undefines_domain_and_deletes_overlay(self):
        harness = Harness.__new__(Harness)
        harness.vm_owned_by_harness = {"omashiki-node-1"}
        harness.vm_created_by_run = set()
        harness.created_volumes = set()
        harness.libvirt_base_path = "/var/lib/libvirt/images/fedora44-base.qcow2"
        harness.report = {"evidence": {}}
        harness.virsh = Mock(side_effect=[
            "omashiki-node-1",
            "shut off",
            "<volume/>",
            "",
            "error: storage vol not found",
        ])
        harness.domain_snapshot = Mock(return_value={
            "initial_state": "shut off",
            "domain_xml": "<domain/>",
            "volume": {"xml": "<volume/>"},
        })
        harness.expected_domain_xml = Mock(return_value=True)
        harness.domain_owned = Mock(return_value=True)
        harness.volume_owned = Mock(return_value=True)
        harness.local = Mock(return_value=Mock(returncode=0))

        self.assertTrue(harness.remove_owned_vms())
        self.assertIn(
            call(["virsh", "-c", "qemu:///system", "undefine", "omashiki-node-1"], check=False),
            harness.local.call_args_list,
        )
        self.assertIn(
            call(["virsh", "-c", "qemu:///system", "vol-delete", "omashiki-node-1.qcow2", "--pool", "images"], check=False),
            harness.local.call_args_list,
        )

    def test_cleanup_completeness_requires_dynamic_guest_keys(self):
        harness = Harness.__new__(Harness)
        harness.cleanup_errors = []
        harness.vm_names = ("omashiki-node-1", "omashiki-node-2")
        harness.remote_pids = {"omashiki-node-1:fake": {}}
        harness.report = {"cleanup": {
            "host_processes_stopped": True,
            "reverse_tunnels_stopped": True,
            "evidence_logs_copied": True,
            "temporary_auth_removed": True,
            "runtime_removed": True,
            "database_removed": True,
            "labelled_containers_absent": True,
            "vms_stopped": True,
            "vm_retention_complete": True,
            "guest_known_hosts_additions_removed": True,
            "guest_authorized_keys_restored": True,
            "guest_runtime_restored": True,
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

    def test_manifest_rejects_inconsistent_workload_before_harness_mutation(self):
        manifest = load_manifest(Path(__file__).parent / "manifest.toml")
        manifest["workload"]["count"] = 1

        with self.assertRaises(Blocker):
            validate_manifest(manifest, Path("manifest.toml"))

    def test_db_query_fails_closed_when_psql_fails(self):
        harness = Harness.__new__(Harness)
        harness.db_container = "db"
        harness.local = Mock(return_value=Mock(returncode=1, stdout=b"database unavailable"))

        with self.assertRaises(E2EError):
            harness.db_query("SELECT 1")

    def test_lock_symlink_is_rejected_before_open(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        target = Path(directory.name) / "target"
        target.touch()
        lock = Path(directory.name) / "lock"
        lock.symlink_to(target)
        harness = Harness.__new__(Harness)

        with patch("e2e.LOCK_PATH", lock), self.assertRaises(Blocker):
            harness.acquire_lock()

    def test_remote_process_query_failure_is_not_interpreted_as_empty(self):
        harness = Harness.__new__(Harness)
        harness.guest_root = Path("/tmp/run")
        harness.ssh_result = Mock(return_value=Mock(returncode=1, stdout=b"timeout"))

        with self.assertRaises(E2EError):
            harness.discover_run_processes("node", "mix phx.server")

    def test_host_process_cleanup_does_not_kill_reused_pid(self):
        harness = Harness.__new__(Harness)
        process = Mock()
        process.poll.return_value = None
        harness.host_processes = {"core": process}
        harness.host_process_metadata = {"core": {"pid": 42, "starttime": 1, "pgrp": 42, "session": 42, "cmdline": "mix phx.server"}}
        harness.read_host_process_identity = Mock(return_value={"pid": 42, "starttime": 2, "pgrp": 42, "session": 42, "cmdline": "mix phx.server"})
        harness.port_free = Mock(return_value=True)

        self.assertFalse(harness.stop_host_processes())
        process.wait.assert_called_once_with(timeout=10)

    def test_host_process_identity_allows_exec_cmdline_change(self):
        harness = Harness.__new__(Harness)
        expected = {"pid": 42, "starttime": 1, "pgrp": 42, "session": 42, "cmdline": "mix phx.server"}
        current = {**expected, "cmdline": "beam.smp -- -extra mix phx.server"}

        self.assertTrue(harness.same_process_identity(current, expected))

    def test_remote_process_identity_ignores_report_metadata(self):
        harness = Harness.__new__(Harness)
        current = {"pid": 42, "starttime": 1, "pgrp": 42, "session": 42, "proc_pgrp": 42,
                   "proc_session": 42, "cmdline": "mix phx.server", "cwd": "/tmp/run"}
        expected = {**current, "name": "node-1", "expected": "mix phx.server", "run_root": "/tmp/run"}

        self.assertTrue(harness.same_remote_process_identity(current, expected))


if __name__ == "__main__":
    unittest.main()
