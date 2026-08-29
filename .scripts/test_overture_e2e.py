#!/usr/bin/env python3
"""Focused tests for the isolated Overture E2E config generator."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tomllib
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("overture_e2e.py")
SPEC = importlib.util.spec_from_file_location("overture_e2e", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ConfigIsolationTests(unittest.TestCase):
    def test_strip_loadtest_local_removes_only_marked_block(self):
        source = "before\n# >>> loadtest-local begin (do not commit)\nsecret\n# <<< loadtest-local end\nafter\n"

        self.assertEqual(MODULE._strip_loadtest_local(source), "before\nafter\n")

    def test_strip_loadtest_local_rejects_unclosed_block(self):
        with self.assertRaisesRegex(SystemExit, "malformed loadtest-local"):
            MODULE._strip_loadtest_local("# >>> loadtest-local begin (do not commit)\nsecret")

    def test_strip_toml_table_removes_only_selected_table(self):
        source = "[one]\nvalue = 1\n\n[two]\nvalue = 2\n"

        self.assertEqual(MODULE._strip_toml_table(source, "[one]"), "[two]\nvalue = 2")

    def test_jcode_stub_uses_fake_openai_target_for_each_runtime(self):
        with patch.dict(os.environ, {}, clear=True):
            for runtime_handler in ("runc", "kata"):
                with self.subTest(runtime_handler=runtime_handler):
                    config = tomllib.loads(
                        MODULE._jcode_stanza(runtime_handler, "jcode-stub")
                    )

                    self.assertEqual(
                        config["credentials"]["jcode-stub"],
                        {
                            "provider": "openai",
                            "model": "fake-model",
                            "base_url": "http://127.0.0.1:8787/v1",
                            "api_key": "unused-by-the-stub",
                        },
                    )
                    self.assertEqual(
                        config["presets"]["jcode-stub"],
                        {
                            "plugin": "jcode",
                            "options": {
                                "timeout_ms": 900000 if runtime_handler == "runc" else 1800000,
                                "model": "fake-model",
                            },
                        },
                    )
                    self.assertEqual(
                        config["environments"]["e2e-jcode"]["preset"],
                        "jcode-stub",
                    )
                    self.assertEqual(
                        config["environments"]["e2e-jcode"]["credentials"],
                        ["jcode-stub"],
                    )
                    self.assertEqual(
                        config["environments"]["e2e-jcode"]["runtime"],
                        f"docker.{runtime_handler}.debian",
                    )

    def test_jcode_still_requires_the_explicit_local_model_url(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(SystemExit, "OMASHIKI_LOCAL_LLM_BASE_URL is unset"):
                MODULE._jcode_stanza("runc", "jcode")

        with patch.dict(
            os.environ,
            {"OMASHIKI_LOCAL_LLM_BASE_URL": "http://model-host:8080/v1"},
            clear=True,
        ):
            config = tomllib.loads(MODULE._jcode_stanza("runc", "jcode"))

        self.assertEqual(
            config["credentials"]["local-llm"],
            {
                "provider": "llamacpp",
                "model": "qwen/qwen3.5-9b",
                "base_url": "http://model-host:8080/v1",
                "api_key": "unused-by-llama-server",
            },
        )
        self.assertEqual(config["presets"]["jcode"]["plugin"], "jcode")
        self.assertEqual(
            config["environments"]["e2e-jcode"]["credentials"], ["local-llm"]
        )


if __name__ == "__main__":
    unittest.main()
