"""Unit tests for the example GitHub issue handler (stdlib only)."""

from __future__ import annotations

import hashlib
import hmac
import importlib.util
import io
import json
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "github_issue_handler", Path(__file__).with_name("github_issue_handler.py")
)
handler = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(handler)


CFG = {
    "omashiki_url": "http://house:4010",
    "omashiki_token": "tok",
    "environment": "triagem",
    "repo": "app",
    "omashiki_webhook_secret": "house-secret",
    "github_webhook_secret": "gh-secret",
    "label": "omashiki",
    "port": 0,
}


def labeled_event(label: str = "omashiki", **overrides):
    event = {
        "action": "labeled",
        "label": {"id": 42, "name": label},
        "issue": {
            "number": 7,
            "title": "Login page throws 500",
            "body": "Steps: open /login",
            "html_url": "https://github.test/acme/app/issues/7",
            "labels": [{"name": "bug"}, {"name": label}],
            "user": {"login": "ana"},
        },
        "repository": {"id": 99, "full_name": "acme/app"},
    }
    event.update(overrides)
    return event


class GithubSignatureTest(unittest.TestCase):
    def test_accepts_a_correct_signature_and_rejects_the_rest(self):
        body = b'{"x":1}'
        good = "sha256=" + hmac.new(b"gh-secret", body, hashlib.sha256).hexdigest()
        handler.verify_github_signature("gh-secret", body, good)

        for bad in (None, "", "sha1=abc", "sha256=" + "0" * 64):
            with self.assertRaises(handler.HandlerError) as ctx:
                handler.verify_github_signature("gh-secret", body, bad)
            self.assertEqual(ctx.exception.status, 401)


class EnvelopeTest(unittest.TestCase):
    def test_a_labelled_issue_becomes_one_envelope_with_the_environment_name(self):
        envelope = handler.envelope_for("issues", labeled_event(), CFG)

        self.assertEqual(envelope["environment"], "triagem")
        self.assertEqual(envelope["repo"], "app")
        self.assertEqual(envelope["correlation_id"], "github:acme/app#7")
        self.assertEqual(envelope["idempotency_key"], "github-99-7-42")
        self.assertEqual(envelope["payload"]["title"], "issue-7-login-page-throws-500")
        self.assertEqual(envelope["payload"]["instruction"], "Login page throws 500\n\nSteps: open /login")
        self.assertEqual(envelope["payload"]["context"]["repository"], "acme/app")
        self.assertEqual(envelope["payload"]["context"]["labels"], ["bug", "omashiki"])
        self.assertEqual(set(envelope["payload"]), {"instruction", "title", "context"})

    def test_nothing_github_specific_leaks_outside_payload_context(self):
        envelope = handler.envelope_for("issues", labeled_event(), CFG)
        top_level = {key for key in envelope if key != "payload"}
        self.assertEqual(top_level, {"idempotency_key", "correlation_id", "environment", "priority", "repo"})

    def test_other_events_and_labels_are_ignored(self):
        self.assertIsNone(handler.envelope_for("issues", labeled_event(label="wontfix"), CFG))
        self.assertIsNone(handler.envelope_for("issues", labeled_event(action="opened"), CFG))
        self.assertIsNone(handler.envelope_for("pull_request", labeled_event(), CFG))

    def test_a_missing_repo_setting_omits_repo(self):
        cfg = dict(CFG, repo=None)
        self.assertNotIn("repo", handler.envelope_for("issues", labeled_event(), cfg))

    def test_a_malformed_event_is_a_400(self):
        with self.assertRaises(handler.HandlerError) as ctx:
            handler.envelope_for("issues", labeled_event(issue={"title": "x"}), CFG)
        self.assertEqual(ctx.exception.status, 400)


class SubmitTest(unittest.TestCase):
    def test_posts_the_envelope_with_bearer_and_idempotency_header(self):
        seen = {}

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def opener(request, timeout):
            seen["url"] = request.full_url
            seen["headers"] = {k.lower(): v for k, v in request.header_items()}
            seen["body"] = json.loads(request.data)
            return Response(b'{"data":{"id":"job-1"}}')

        envelope = handler.envelope_for("issues", labeled_event(), CFG)
        result = handler.submit_job(CFG, envelope, opener)

        self.assertEqual(result["data"]["id"], "job-1")
        self.assertEqual(seen["url"], "http://house:4010/api/v1/jobs")
        self.assertEqual(seen["headers"]["authorization"], "Bearer tok")
        self.assertEqual(seen["headers"]["idempotency-key"], "github-99-7-42")
        self.assertEqual(seen["body"]["environment"], "triagem")


class OmashikiSignatureTest(unittest.TestCase):
    def payload(self, at: datetime):
        return {            "event_id": "evt-1",
            "timestamp": at.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "job_id": "job-1",
            "attempt_id": "att-1",
            "attempt": 1,
            "status": "succeeded",
            "correlation_id": "github:acme/app#7",
            "git": {"branch": "issue-7-login", "base_sha": "a", "head_sha": "b", "worktree_clean": True},
        }

    def sign(self, secret: str, payload: dict) -> str:
        signing_input = (payload["timestamp"] + "." + handler.canonical_json(payload)).encode()
        return "v1=" + hmac.new(secret.encode(), signing_input, hashlib.sha256).hexdigest()

    def test_canonical_json_sorts_keys_recursively_without_spaces(self):
        self.assertEqual(
            handler.canonical_json({"b": [1, {"z": None, "a": "é"}], "a": True}),
            '{"a":true,"b":[1,{"a":"é","z":null}]}',
        )

    def test_accepts_a_fresh_correctly_signed_payload(self):
        now = datetime.now(timezone.utc)
        payload = self.payload(now)
        handler.verify_omashiki_signature(["house-secret"], payload, self.sign("house-secret", payload), now=now)

    def test_rejects_wrong_secret_replay_and_malformed_header(self):
        now = datetime.now(timezone.utc)
        payload = self.payload(now)
        good = self.sign("house-secret", payload)

        with self.assertRaises(handler.HandlerError):
            handler.verify_omashiki_signature(["other"], payload, good, now=now)
        with self.assertRaises(handler.HandlerError) as ctx:
            handler.verify_omashiki_signature(["house-secret"], payload, good, now=now + timedelta(minutes=10))
        self.assertEqual(ctx.exception.message, "replay or expired")
        with self.assertRaises(handler.HandlerError):
            handler.verify_omashiki_signature(["house-secret"], payload, "sha256=abc", now=now)

    def test_a_rotated_previous_secret_still_verifies(self):
        now = datetime.now(timezone.utc)
        payload = self.payload(now)
        handler.verify_omashiki_signature(["new", "house-secret"], payload, self.sign("house-secret", payload), now=now)

    def test_on_terminal_reports_status_and_branch(self):
        lines = []
        handler.on_terminal(self.payload(datetime.now(timezone.utc)), log=lines.append)
        self.assertEqual(lines, ["job job-1 succeeded for github:acme/app#7 branch=issue-7-login head=b"])


class HttpTest(unittest.TestCase):
    """The two endpoints over a real socket, with the house faked."""

    def setUp(self):
        from http.server import ThreadingHTTPServer
        import threading
        import urllib.request

        self.seen = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def opener(request, timeout):
            self.seen.append(json.loads(request.data))
            return Response(b'{"data":{"id":"job-9"}}')

        handler.Handler.cfg = dict(CFG)
        handler.Handler.opener = staticmethod(opener)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler.Handler)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.urlopen = urllib.request.urlopen
        self.Request = urllib.request.Request

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def post(self, path, body: bytes, headers: dict):
        import urllib.error

        request = self.Request(self.base + path, data=body, method="POST", headers=headers)
        try:
            with self.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_github_label_admits_a_job_and_unsigned_calls_are_refused(self):
        body = json.dumps(labeled_event()).encode()
        signature = "sha256=" + hmac.new(b"gh-secret", body, hashlib.sha256).hexdigest()

        status, reply = self.post("/github", body, {"x-github-event": "issues", "x-hub-signature-256": signature})
        self.assertEqual((status, reply["job_id"]), (202, "job-9"))
        self.assertEqual(self.seen[-1]["environment"], "triagem")

        status, reply = self.post("/github", body, {"x-github-event": "issues"})
        self.assertEqual(status, 401)
        self.assertEqual(len(self.seen), 1)

        other = json.dumps(labeled_event(label="wontfix")).encode()
        signature = "sha256=" + hmac.new(b"gh-secret", other, hashlib.sha256).hexdigest()
        status, reply = self.post("/github", other, {"x-github-event": "issues", "x-hub-signature-256": signature})
        self.assertEqual((status, reply), (200, {"ignored": True}))

    def test_terminal_webhook_is_verified(self):
        now = datetime.now(timezone.utc)
        payload = OmashikiSignatureTest.payload(OmashikiSignatureTest(), now)
        body = json.dumps(payload).encode()
        signature = OmashikiSignatureTest.sign(OmashikiSignatureTest(), "house-secret", payload)

        status, reply = self.post("/omashiki", body, {"x-webhook-signature": signature})
        self.assertEqual((status, reply), (200, {"ok": True}))

        status, _ = self.post("/omashiki", body, {"x-webhook-signature": "v1=" + "0" * 64})
        self.assertEqual(status, 401)


class ConfigTest(unittest.TestCase):
    def test_required_variables_are_enforced(self):
        with self.assertRaises(SystemExit):
            handler.config_from_env({"OMASHIKI_URL": "http://h"})

        cfg = handler.config_from_env({
            "OMASHIKI_URL": "http://h/",
            "OMASHIKI_TOKEN": "t",
            "OMASHIKI_ENVIRONMENT": "triagem",
            "GITHUB_WEBHOOK_SECRET": "s",
        })
        self.assertEqual(cfg["omashiki_url"], "http://h")
        self.assertEqual(cfg["label"], "omashiki")
        self.assertIsNone(cfg["repo"])
        self.assertIsNone(cfg["omashiki_webhook_secret"])


if __name__ == "__main__":
    unittest.main()
