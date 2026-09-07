#!/usr/bin/env python3
"""A client at the door: GitHub issues become Omashiki jobs, and back.

This is the "client at the door" from docs/concepts/client-at-the-door.md. It is not part of
Omashiki. It is what *you* run in front of a house, and it is the whole
integration surface:

    GitHub  --(webhook)-->  this handler  --(POST /api/v1/jobs)-->  Omashiki
    Omashiki --(signed terminal webhook)--> this handler --> your ticket

Two endpoints:

  POST /github     GitHub webhook receiver. Verifies X-Hub-Signature-256 with
                   GITHUB_WEBHOOK_SECRET. On `issues.labeled` with the trigger
                   label, POSTs one job envelope to the house: environment
                   *name*, instruction, context. Nothing GitHub-specific goes
                   into omashiki.toml, the sandbox, or the worker.

  POST /omashiki   Omashiki terminal webhook receiver. Verifies
                   x-webhook-signature (v1 HMAC over timestamp + "." +
                   canonical JSON) with OMASHIKI_WEBHOOK_SECRET and reports the
                   job's terminal status and branch. Extend `on_terminal` to
                   post that back onto the issue with *your* token — the
                   handler is a client, not the agent's identity.

Configuration is environment variables only:

  OMASHIKI_URL              e.g. http://127.0.0.1:4010
  OMASHIKI_TOKEN            API token that may submit jobs (Bearer)
  OMASHIKI_ENVIRONMENT      environment name declared in the house (e.g. triagem)
  OMASHIKI_REPO             optional registered repository name for git sinks
  OMASHIKI_WEBHOOK_SECRET   secret configured on that token's webhook destination
  GITHUB_WEBHOOK_SECRET     secret configured on the GitHub webhook
  HANDLER_LABEL             trigger label, default "omashiki"
  HANDLER_PORT              listen port, default 8090

Run:  python3 examples/handler/github_issue_handler.py
Test: python3 -m unittest examples/handler/test_github_issue_handler.py
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class HandlerError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------------------------------------------------------------------------
# Configuration


def config_from_env(env: dict[str, str] | None = None) -> dict[str, Any]:
    env = os.environ if env is None else env

    def required(name: str) -> str:
        value = env.get(name, "").strip()
        if not value:
            raise SystemExit(f"{name} is required")
        return value

    return {
        "omashiki_url": required("OMASHIKI_URL").rstrip("/"),
        "omashiki_token": required("OMASHIKI_TOKEN"),
        "environment": required("OMASHIKI_ENVIRONMENT"),
        "repo": env.get("OMASHIKI_REPO", "").strip() or None,
        "omashiki_webhook_secret": env.get("OMASHIKI_WEBHOOK_SECRET", "").strip() or None,
        "github_webhook_secret": required("GITHUB_WEBHOOK_SECRET"),
        "label": env.get("HANDLER_LABEL", "omashiki").strip() or "omashiki",
        "port": int(env.get("HANDLER_PORT", "8090")),
    }


# ---------------------------------------------------------------------------
# GitHub side


def verify_github_signature(secret: str, body: bytes, header: str | None) -> None:
    """GitHub signs the raw body: sha256=<hex HMAC-SHA256>."""
    if not header or not header.startswith("sha256="):
        raise HandlerError(401, "missing X-Hub-Signature-256")
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, header[len("sha256="):]):
        raise HandlerError(401, "invalid X-Hub-Signature-256")


def slug(text: str, limit: int = 40) -> str:
    text = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return text[:limit].rstrip("-") or "issue"


def envelope_for(event_name: str, event: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any] | None:
    """Map one GitHub event to one job envelope, or None when it is not ours.

    Only `issues.labeled` with the trigger label is work. Everything else
    (edits, other labels, pull requests) is acknowledged and ignored: the
    handler owns the event mapping, the house never sees GitHub.
    """
    if event_name != "issues" or event.get("action") != "labeled":
        return None
    if (event.get("label") or {}).get("name") != cfg["label"]:
        return None

    issue = event.get("issue") or {}
    repository = event.get("repository") or {}
    number = issue.get("number")
    full_name = repository.get("full_name")
    if not isinstance(number, int) or not full_name:
        raise HandlerError(400, "issue.number and repository.full_name are required")

    title = (issue.get("title") or "").strip() or f"Issue #{number}"
    body = (issue.get("body") or "").strip()
    instruction = title if not body else f"{title}\n\n{body}"

    envelope: dict[str, Any] = {
        "schema_version": 1,
        # One job per labelling of one issue: re-labelling after removal is new
        # work, retries of the same delivery are not.
        "idempotency_key": f"github-{repository.get('id', full_name)}-{number}-{(event.get('label') or {}).get('id', cfg['label'])}",
        "correlation_id": f"github:{full_name}#{number}",
        "environment": cfg["environment"],
        "priority": 1,
        "payload": {
            "instruction": instruction,
            "title": f"issue-{number}-{slug(title)}",
            "context": {
                "source": "github",
                "repository": full_name,
                "number": number,
                "url": issue.get("html_url"),
                "labels": [label.get("name") for label in issue.get("labels") or [] if label.get("name")],
                "author": (issue.get("user") or {}).get("login"),
            },
        },
    }
    if cfg["repo"]:
        envelope["repo"] = cfg["repo"]
    return envelope


def submit_job(cfg: dict[str, Any], envelope: dict[str, Any], opener=urllib.request.urlopen) -> dict[str, Any]:
    request = urllib.request.Request(
        cfg["omashiki_url"] + "/api/v1/jobs",
        data=json.dumps(envelope).encode(),
        method="POST",
        headers={
            "content-type": "application/json",
            "authorization": "Bearer " + cfg["omashiki_token"],
            "idempotency-key": envelope["idempotency_key"],
        },
    )
    try:
        with opener(request, timeout=15) as response:
            return json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise HandlerError(502, f"omashiki rejected the job: {error.code} {detail[:300]}") from error
    except urllib.error.URLError as error:
        raise HandlerError(502, f"omashiki unreachable: {error.reason}") from error


# ---------------------------------------------------------------------------
# Omashiki side (terminal webhook)


def canonical_json(value: Any) -> str:
    """Byte-for-byte the house's canonical encoding: sorted keys, no spaces."""
    if isinstance(value, dict):
        return "{" + ",".join(
            json.dumps(str(key), ensure_ascii=False) + ":" + canonical_json(value[key])
            for key in sorted(value, key=str)
        ) + "}"
    if isinstance(value, list):
        return "[" + ",".join(canonical_json(item) for item in value) + "]"
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def verify_omashiki_signature(secrets: list[str], payload: dict[str, Any], header: str | None,
                              now: datetime | None = None, max_age_seconds: int = 300) -> None:
    """v1=<hex HMAC-SHA256(secret, timestamp + "." + canonical_json(payload))>."""
    match = re.fullmatch(r"v1=([0-9a-f]{64})", header or "")
    if not match:
        raise HandlerError(401, "missing or malformed x-webhook-signature")

    timestamp = payload.get("timestamp")
    if not isinstance(timestamp, str):
        raise HandlerError(401, "payload.timestamp missing")
    try:
        at = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError as error:
        raise HandlerError(401, "payload.timestamp invalid") from error
    now = now or datetime.now(timezone.utc)
    if abs((now - at).total_seconds()) > max_age_seconds:
        raise HandlerError(401, "replay or expired")

    signing_input = (timestamp + "." + canonical_json(payload)).encode()
    for secret in secrets:
        expected = hmac.new(secret.encode(), signing_input, hashlib.sha256).hexdigest()
        if hmac.compare_digest(expected, match.group(1)):
            return
    raise HandlerError(401, "invalid x-webhook-signature")


def on_terminal(payload: dict[str, Any], log=print) -> None:
    """The end of the job reaches the ticket through *this* process.

    Replace the log line with a comment on the issue using your own GitHub
    token: `payload["correlation_id"]` is `github:owner/name#number`.
    """
    git = payload.get("git") or {}
    log(
        f"job {payload.get('job_id')} {payload.get('status')} "
        f"for {payload.get('correlation_id')} branch={git.get('branch')} head={git.get('head_sha')}"
    )


# ---------------------------------------------------------------------------
# HTTP


class Handler(BaseHTTPRequestHandler):
    cfg: dict[str, Any] = {}
    opener = staticmethod(urllib.request.urlopen)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self._json(200, {"status": "ok"})
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        try:
            body = self.rfile.read(int(self.headers.get("content-length") or 0))
            if self.path == "/github":
                self._github(body)
            elif self.path == "/omashiki":
                self._omashiki(body)
            else:
                raise HandlerError(404, "not_found")
        except HandlerError as error:
            self._json(error.status, {"error": error.message})
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid_json"})

    def _github(self, body: bytes) -> None:
        verify_github_signature(self.cfg["github_webhook_secret"], body, self.headers.get("x-hub-signature-256"))
        event_name = self.headers.get("x-github-event", "")
        if event_name == "ping":
            self._json(200, {"ok": True})
            return
        envelope = envelope_for(event_name, json.loads(body or b"{}"), self.cfg)
        if envelope is None:
            self._json(200, {"ignored": True})
            return
        job = submit_job(self.cfg, envelope, self.opener)
        job_id = (job.get("data") or {}).get("id")
        self.log_message("admitted job %s for %s", job_id, envelope["correlation_id"])
        self._json(202, {"job_id": job_id, "correlation_id": envelope["correlation_id"]})

    def _omashiki(self, body: bytes) -> None:
        secret = self.cfg.get("omashiki_webhook_secret")
        if not secret:
            raise HandlerError(503, "OMASHIKI_WEBHOOK_SECRET not configured")
        payload = json.loads(body or b"{}")
        verify_omashiki_signature([secret], payload, self.headers.get("x-webhook-signature"))
        on_terminal(payload, log=lambda line: self.log_message("%s", line))
        self._json(200, {"ok": True})

    def _json(self, status: int, value: dict[str, Any]) -> None:
        encoded = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter than the default
        sys.stderr.write("[handler] " + (fmt % args) + "\n")


def serve(cfg: dict[str, Any]) -> None:
    Handler.cfg = cfg
    server = ThreadingHTTPServer(("0.0.0.0", cfg["port"]), Handler)
    sys.stderr.write(
        f"[handler] listening on :{cfg['port']} — label '{cfg['label']}' -> environment '{cfg['environment']}' at {cfg['omashiki_url']}\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    serve(config_from_env())
