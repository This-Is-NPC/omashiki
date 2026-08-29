#!/usr/bin/env python3
"""Focused tests for prepared VM base publication and verification."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))

from prepare import Preparer  # noqa: E402
from e2e import Blocker  # noqa: E402
from prepared import (  # noqa: E402
    PreparedBaseError,
    atomic_write_json,
    preparation_fingerprint,
    prepared_paths,
    verify_prepared_base,
)


class PreparedBaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "vm").mkdir()
        (self.root / "server").mkdir()
        self.manifest_path = self.root / "vm" / "manifest.toml"
        self.manifest_path.write_text("manifest fixture\n")
        for relative in ("vm/prepare.py", "vm/prepared.py", "vm/e2e.py", "vm/prepare-cloud-init.yaml",
                         "server/mix.exs", "server/mix.lock"):
            path = self.root / relative
            path.write_text(relative + "\n")
        self.pointer = self.root / "cache" / "prepared.json"
        self.pointer.parent.mkdir(mode=0o700)
        self.images = self.root / "images"
        self.images.mkdir(mode=0o700)
        self.manifest = {
            "base": {"pool": "images", "sha256": "a" * 64},
            "prepared": {
                "directory": str(self.images),
                "pointer": str(self.pointer),
                "volume_prefix": "omashiki-test",
                "cloud_init": "vm/prepare-cloud-init.yaml",
            },
        }

    def test_fingerprint_is_deterministic_and_tracks_inputs(self) -> None:
        first = preparation_fingerprint(self.manifest, self.manifest_path)
        self.assertEqual(first, preparation_fingerprint(self.manifest, self.manifest_path))

        (self.root / "server" / "mix.lock").write_text("changed\n")

        self.assertNotEqual(first, preparation_fingerprint(self.manifest, self.manifest_path))

    def test_prepared_paths_are_content_addressed(self) -> None:
        fingerprint = "b" * 64

        host_path, volume = prepared_paths(self.manifest, fingerprint)

        self.assertEqual(host_path, self.images / f"{fingerprint}.qcow2")
        self.assertEqual(volume, "omashiki-test-bbbbbbbbbbbbbbbb.qcow2")

    def publish_fixture(self) -> tuple[dict, Path, Path]:
        fingerprint = preparation_fingerprint(self.manifest, self.manifest_path)
        host_path, volume = prepared_paths(self.manifest, fingerprint)
        libvirt_path = self.root / "libvirt.qcow2"
        host_path.write_bytes(b"prepared image")
        libvirt_path.write_bytes(b"prepared image")
        os.chmod(host_path, 0o644)
        os.chmod(libvirt_path, 0o644)
        import hashlib
        digest = hashlib.sha256(b"prepared image").hexdigest()
        pointer = {
            "fingerprint": fingerprint,
            "source_sha256": "a" * 64,
            "host_path": str(host_path),
            "volume": volume,
            "libvirt_path": str(libvirt_path),
            "sha256": digest,
            "size": len(b"prepared image"),
            "virtual_size": 4096,
        }
        atomic_write_json(self.pointer, pointer)
        return pointer, host_path, libvirt_path

    def verify_commands(self, pointer: dict):
        info = {"format": "qcow2", "virtual-size": 4096}
        xml = (
            "<volume><name>" + pointer["volume"] + "</name><target><path>"
            + pointer["libvirt_path"] + "</path><format type='qcow2'/></target></volume>"
        )

        def text(command, _label):
            return pointer["libvirt_path"] if "vol-path" in command else xml

        return patch("prepared._command_json", return_value=info), patch("prepared._command_text", side_effect=text)

    def test_verify_accepts_exact_published_pointer(self) -> None:
        pointer, _host_path, _libvirt_path = self.publish_fixture()
        json_command, text_command = self.verify_commands(pointer)

        with json_command, text_command:
            self.assertEqual(
                verify_prepared_base(self.manifest, self.manifest_path),
                pointer,
            )

    def test_verify_rejects_corrupted_host_image(self) -> None:
        pointer, host_path, _libvirt_path = self.publish_fixture()
        host_path.write_bytes(b"corrupt")
        json_command, text_command = self.verify_commands(pointer)

        with json_command, text_command, self.assertRaises(PreparedBaseError):
            verify_prepared_base(self.manifest, self.manifest_path)

    def test_verify_rejects_symlinked_pointer(self) -> None:
        self.pointer.symlink_to(self.root / "missing")

        with self.assertRaises(PreparedBaseError):
            verify_prepared_base(self.manifest, self.manifest_path)


class PreparationRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.preparer = Preparer.__new__(Preparer)
        self.preparer.manifest = {
            "prepared": {"directory": str(self.root), "volume_prefix": "omashiki-test"},
        }
        self.preparer.pool = "images"
        self.preparer.qemu_uri = "qemu:///system"
        self.preparer.pending_path = self.root / "pending.json"
        self.preparer.candidate_path = self.root / ".candidate.qcow2"
        self.preparer.run = Mock()

    def test_recovery_removes_safe_artifacts_from_an_old_fingerprint(self) -> None:
        fingerprint = "c" * 64
        host_path, volume = prepared_paths(self.preparer.manifest, fingerprint)
        host_path.write_bytes(b"partial")
        atomic_write_json(self.preparer.pending_path, {
            "fingerprint": fingerprint,
            "host_path": str(host_path),
            "volume": volume,
        })
        self.preparer.virsh = Mock(return_value="error: Storage volume not found")

        self.preparer.recover_pending_publication()

        self.assertFalse(host_path.exists())
        self.assertFalse(self.preparer.pending_path.exists())
        self.preparer.run.assert_not_called()

    def test_recovery_refuses_symlinked_host_artifact(self) -> None:
        fingerprint = "d" * 64
        host_path, volume = prepared_paths(self.preparer.manifest, fingerprint)
        target = self.root / "target"
        target.write_bytes(b"keep")
        host_path.symlink_to(target)
        atomic_write_json(self.preparer.pending_path, {
            "fingerprint": fingerprint,
            "host_path": str(host_path),
            "volume": volume,
        })
        self.preparer.virsh = Mock(return_value="error: Storage volume not found")

        with self.assertRaisesRegex(Blocker, "unsafe pending host image"):
            self.preparer.recover_pending_publication()

        self.assertEqual(target.read_bytes(), b"keep")

    def test_candidate_cleanup_refuses_symlink(self) -> None:
        target = self.root / "target-candidate"
        target.write_bytes(b"keep")
        self.preparer.candidate_path.symlink_to(target)

        with self.assertRaisesRegex(Blocker, "unsafe prepared candidate"):
            self.preparer.cleanup_candidate()

        self.assertEqual(target.read_bytes(), b"keep")

    def test_valid_current_base_is_an_idempotent_noop(self) -> None:
        self.preparer.pointer_path = self.root / "prepared.json"
        self.preparer.pointer_path.write_text("{}")
        os.chmod(self.preparer.pointer_path, 0o600)
        self.preparer.manifest_path = self.root / "manifest.toml"
        self.preparer.qemu_uri = "qemu:///system"
        self.preparer.log = Mock()

        with patch("prepare.verify_prepared_base", return_value={"fingerprint": "e" * 64}):
            self.assertTrue(self.preparer.current_is_valid())


if __name__ == "__main__":
    unittest.main()
