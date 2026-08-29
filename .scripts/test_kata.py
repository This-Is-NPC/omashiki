#!/usr/bin/env python3
"""Focused stdlib checks for the host-only Kata scripts."""

from __future__ import annotations

import os
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / ".scripts"
ARCHIVE_PATHS_SCRIPT = SCRIPTS / "kata_archive_paths.py"
ARCHIVE_PATHS_SPEC = importlib.util.spec_from_file_location(
    "kata_archive_paths", ARCHIVE_PATHS_SCRIPT
)
ARCHIVE_PATHS = importlib.util.module_from_spec(ARCHIVE_PATHS_SPEC)
assert ARCHIVE_PATHS_SPEC.loader is not None
ARCHIVE_PATHS_SPEC.loader.exec_module(ARCHIVE_PATHS)
RUNTIME_CONFIG_SCRIPT = SCRIPTS / "kata_runtime_config.py"
RUNTIME_CONFIG_SPEC = importlib.util.spec_from_file_location(
    "kata_runtime_config", RUNTIME_CONFIG_SCRIPT
)
RUNTIME_CONFIG = importlib.util.module_from_spec(RUNTIME_CONFIG_SPEC)
assert RUNTIME_CONFIG_SPEC.loader is not None
RUNTIME_CONFIG_SPEC.loader.exec_module(RUNTIME_CONFIG)


class KataScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = (SCRIPTS / "kata_install.sh").read_text(encoding="utf-8")
        cls.smoke = (SCRIPTS / "kata_smoke.sh").read_text(encoding="utf-8")

    def test_manifest_pin_and_paths_match_installer_contract(self) -> None:
        with (ROOT / "vm" / "manifest.toml").open("rb") as source:
            kata = tomllib.load(source)["runtime"]["kata"]

        self.assertEqual(kata["version"], "4.1.0")
        self.assertEqual(kata["archive"], "kata-static-4.1.0-amd64.tar.zst")
        self.assertIsNotNone(re.fullmatch(r"[0-9a-f]{64}", kata["sha256"]))
        self.assertIn("tomllib", self.installer)
        self.assertIn("sha256sum", self.installer)
        self.assertIn("/dev/kvm", self.installer)

    def test_archive_paths_accept_normal_and_dot_prefixed_kata_roots(self) -> None:
        for root in ("opt/kata", "./opt/kata"):
            with self.subTest(root=root):
                ARCHIVE_PATHS.validate(
                    [f"{root}/", f"{root}/bin/cloud-hypervisor"]
                )

    def test_archive_paths_reject_traversal_absolute_and_missing_roots(self) -> None:
        for entries in (
            ["../opt/kata/bin/cloud-hypervisor"],
            ["/opt/kata/bin/cloud-hypervisor"],
            ["usr/bin/unrelated"],
        ):
            with self.subTest(entries=entries):
                with self.assertRaises(ARCHIVE_PATHS.ArchivePathError):
                    ARCHIVE_PATHS.validate(entries)

    def test_installer_shows_download_activity_and_phase_feedback(self) -> None:
        self.assertIn("--progress-bar", self.installer)
        self.assertNotIn("--silent", self.installer)
        for phase in (
            "verifying Kata archive checksum",
            "validating Kata archive paths",
            "extracting Kata archive",
            "installing Kata under",
            "validating updated Docker daemon configuration",
            "restarting Docker to activate runtime kata",
        ):
            self.assertIn(phase, self.installer)

    def test_runtime_config_reads_hypervisor_name_from_runtime_table(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "configuration.toml"
            config.write_text(
                '[hypervisor.clh]\npath = "/opt/kata/bin/cloud-hypervisor"\n\n'
                '[runtime]\nhypervisor_name = "clh"\n',
                encoding="utf-8",
            )

            RUNTIME_CONFIG.validate(config, "/opt/kata/bin/cloud-hypervisor")

    def test_runtime_config_rejects_wrong_table_or_hypervisor_path(self) -> None:
        invalid_documents = (
            '[hypervisor.clh]\npath = "/opt/kata/bin/cloud-hypervisor"\n'
            'hypervisor_name = "clh"\n',
            '[hypervisor.clh]\npath = "/wrong/hypervisor"\n\n'
            '[runtime]\nhypervisor_name = "clh"\n',
        )
        for document in invalid_documents:
            with self.subTest(document=document):
                with tempfile.TemporaryDirectory() as directory:
                    config = Path(directory) / "configuration.toml"
                    config.write_text(document, encoding="utf-8")
                    with self.assertRaises(RUNTIME_CONFIG.RuntimeConfigError):
                        RUNTIME_CONFIG.validate(
                            config, "/opt/kata/bin/cloud-hypervisor"
                        )

    def test_installer_reuses_matching_existing_kata_version(self) -> None:
        self.assertIn("installed_kata_ready", self.installer)
        self.assertIn('version: $KATA_VERSION,', self.installer)
        self.assertIn("reusing validated Kata", self.installer)
        self.assertLess(
            self.installer.index("if installed_kata_ready"),
            self.installer.index("downloading Kata"),
        )

    def test_installer_requires_sudo_and_validates_before_restart(self) -> None:
        self.assertIn("sudo -n", self.installer)
        self.assertIn("SUDO_USER", self.installer)
        self.assertIn("dockerd --validate", self.installer)
        self.assertIn("systemctl restart docker", self.installer)
        normal_restart = self.installer.index(
            '"${SUDO[@]}" systemctl restart docker',
            self.installer.index('if [ "$needs_restart" -eq 1 ]'),
        )
        self.assertLess(
            self.installer.index("dockerd --validate"),
            normal_restart,
        )
        self.assertIn("Docker restart after daemon config rollback failed", self.installer)

    def test_installer_registers_only_the_owned_kata_entry(self) -> None:
        self.assertIn('"runtimeType": str(runtime_path)', self.installer)
        self.assertIn('"ConfigPath": str(config_path)', self.installer)
        self.assertIn('existing is not None and existing != expected', self.installer)
        self.assertIn("os.replace(temporary, candidate_path)", self.installer)

    def test_smoke_is_one_container_runtime_and_cleanup_verified(self) -> None:
        self.assertIn("--runtime kata", self.smoke)
        self.assertIn("HostConfig.Runtime", self.smoke)
        self.assertIn("--label", self.smoke)
        self.assertIn("docker rm -f", self.smoke)
        self.assertIn("cleanup verification failed", self.smoke)
        self.assertNotIn("virt-install", self.smoke)
        self.assertNotIn("virsh", self.smoke)

    def test_smoke_success_path_uses_one_container_and_removes_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake_dir = Path(directory)
            state = fake_dir / "container-present"
            log = fake_dir / "docker.log"
            fake_docker = fake_dir / "docker"
            fake_docker.write_text(
                """#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  info) printf '%s\n' '{"runc": {}, "kata": {}}' ;;
  image) exit 0 ;;
  run) touch "$FAKE_DOCKER_STATE"; printf '%s\n' fake-container ;;
  ps) if [ -e "$FAKE_DOCKER_STATE" ]; then printf '%s\n' fake-container; fi ;;
  inspect) printf '%s\n' kata ;;
  exec) printf '%s\n' kata-smoke-exec-ok ;;
  rm) rm -f "$FAKE_DOCKER_STATE" ;;
  *) exit 1 ;;
esac
""",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{fake_dir}:{os.environ['PATH']}",
                "FAKE_DOCKER_LOG": str(log),
                "FAKE_DOCKER_STATE": str(state),
            }
            result = subprocess.run(
                [str(SCRIPTS / "kata_smoke.sh"), "omashiki/agent-jcode:test"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text(encoding="utf-8").splitlines()
            run_calls = [call for call in calls if call.startswith("run ")]
            self.assertEqual(len(run_calls), 1)
            self.assertIn("--runtime kata", run_calls[0])
            self.assertIn("--label com.omashiki.kata-smoke=", run_calls[0])
            self.assertFalse(state.exists())

if __name__ == "__main__":
    unittest.main()
