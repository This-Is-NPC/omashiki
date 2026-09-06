#!/usr/bin/env python3
"""Unit tests for the two-houses E2E helpers."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("two_houses_e2e.py")
SPEC = importlib.util.spec_from_file_location("two_houses_e2e", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TwoHousesHelperTests(unittest.TestCase):
    def test_each_house_gets_its_own_port_database_and_token(self) -> None:
        ana = MODULE.manager_env("ana", worker_token="tok-a", db_port=5442, config_path=Path("/r/omashiki.e2e.toml"))
        joao = MODULE.manager_env("joao", worker_token="tok-j", db_port=5442, config_path=Path("/r/omashiki.e2e.toml"))

        self.assertNotEqual(ana["PORT"], joao["PORT"])
        self.assertNotEqual(ana["OMASHIKI_DB_NAME"], joao["OMASHIKI_DB_NAME"])
        self.assertEqual((ana["OMASHIKI_WORKER_TOKEN"], joao["OMASHIKI_WORKER_TOKEN"]), ("tok-a", "tok-j"))
        self.assertNotEqual(ana["OMASHIKI_SUPPLY_CHAIN_SOCKET_PATH"], joao["OMASHIKI_SUPPLY_CHAIN_SOCKET_PATH"])
        self.assertEqual(ana["OMASHIKI_NODE"], "house-ana")
        self.assertEqual(ana["OMASHIKI_ROLE"], "manager")

    def test_worker_boots_with_no_house_and_an_enroll_listener(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"OMASHIKI_MANAGER_URL": "http://stale", "OMASHIKI_WORKER_TOKEN": "stale", "OMASHIKI_MANAGERS": "[]"},
            clear=False,
        ):
            env = MODULE.worker_env(enroll_secret="s3")

        for key in ("OMASHIKI_MANAGER_URL", "OMASHIKI_WORKER_TOKEN", "OMASHIKI_MANAGERS", "OMASHIKI_CONFIG"):
            self.assertNotIn(key, env)
        self.assertEqual(env["OMASHIKI_ROLE"], "worker")
        self.assertEqual(env["OMASHIKI_ENROLL_SECRET"], "s3")
        self.assertEqual(env["OMASHIKI_ENROLL_PORT"], str(MODULE.ENROLL_PORT))
        self.assertEqual(env["OMASHIKI_MAX_CONCURRENT_CONTAINERS"], "2")

    def test_isolation_check_accepts_disjoint_houses(self) -> None:
        MODULE.assert_isolated({
            "ana": {"job_id": "a", "result": {"branch": "ana-1"}, "seen_by_others": {"joao": 404}},
            "joao": {"job_id": "b", "result": {"branch": "joao-1"}, "seen_by_others": {"ana": 404}},
        })

    def test_isolation_check_rejects_a_job_visible_in_the_other_house(self) -> None:
        with self.assertRaises(MODULE.E2EError):
            MODULE.assert_isolated({
                "ana": {"job_id": "a", "result": {"branch": "ana-1"}, "seen_by_others": {"joao": 200}},
                "joao": {"job_id": "b", "result": {"branch": "joao-1"}, "seen_by_others": {"ana": 404}},
            })

    def test_isolation_check_rejects_shared_branches(self) -> None:
        with self.assertRaises(MODULE.E2EError):
            MODULE.assert_isolated({
                "ana": {"job_id": "a", "result": {"branch": "same"}, "seen_by_others": {"joao": 404}},
                "joao": {"job_id": "b", "result": {"branch": "same"}, "seen_by_others": {"ana": 404}},
            })


if __name__ == "__main__":
    unittest.main()
