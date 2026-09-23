#!/usr/bin/env python3
"""Unit tests for the shared mise task helpers."""

from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import omashiki  # noqa: E402


class ConfigTests(unittest.TestCase):
    def test_config_reads_the_file_omashiki_config_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "house.toml"
            path.write_text("[app]\nport = 4987\n\n[db]\nport = 5987\n")

            with mock.patch.dict(os.environ, {"OMASHIKI_CONFIG": str(path)}):
                self.assertEqual(omashiki.config_file(), path.resolve())
                self.assertEqual(omashiki.config()["app"]["port"], 4987)

    def test_relative_omashiki_config_is_resolved_against_the_working_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "house.toml").write_text("[app]\nport = 4987\n")
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                with mock.patch.dict(os.environ, {"OMASHIKI_CONFIG": "house.toml"}):
                    self.assertEqual(omashiki.config_file(), Path(tmp, "house.toml").resolve())
                    self.assertEqual(omashiki.config()["app"]["port"], 4987)
            finally:
                os.chdir(cwd)

    def test_config_defaults_to_the_repository_root(self) -> None:
        with mock.patch.dict(os.environ, {"OMASHIKI_CONFIG": ""}):
            self.assertEqual(omashiki.config_file(), omashiki.ROOT / "omashiki.toml")

    def test_missing_file_is_an_empty_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"OMASHIKI_CONFIG": str(Path(tmp) / "absent.toml")}):
                self.assertEqual(omashiki.config(), {})

    def test_task_env_hands_spawned_commands_the_same_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "house.toml").write_text("[app]\nport = 4987\n\n[db]\nport = 5987\n")
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                with mock.patch.dict(os.environ, {"OMASHIKI_CONFIG": "house.toml"}):
                    for var in ("PORT", "OMASHIKI_DB_PORT"):
                        os.environ.pop(var, None)
                    env = omashiki.task_env()
            finally:
                os.chdir(cwd)

        self.assertEqual(env["OMASHIKI_CONFIG"], str(Path(tmp, "house.toml").resolve()))
        self.assertEqual(env["PORT"], "4987")
        self.assertEqual(env["OMASHIKI_DB_PORT"], "5987")


if __name__ == "__main__":
    unittest.main()
