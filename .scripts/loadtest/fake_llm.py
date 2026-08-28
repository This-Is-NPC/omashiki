#!/usr/bin/env python3
"""
OpenAI-compatible LLM stub for Omashiki load tests.

The point of this process is to turn the LLM into a *controlled variable*.
A real provider adds unbounded latency, per-account rate limits, and its own
queueing; measuring Omashiki through one measures the provider instead. This
stub answers `POST /v1/chat/completions` after a configurable sleep, so a load
run measures how many attempts Omashiki can hold open at once.

Why Python and not Node: the two existing tools under `.scripts/` are Python
stdlib (`omashiki.py`, `overture_e2e.py`), `mise.toml` already pins
`python = "3.12"`, and nothing here needs a dependency. A `.mjs` stub would add
a second runtime to the load-test path for no gain.

Concurrency: `ThreadingHTTPServer` handles each connection on its own thread and
`time.sleep` releases the GIL, so N in-flight requests finish in ~LAT_MS, not
N x LAT_MS. `/__stats` reports the observed peak so that property is checkable
from the outside rather than assumed.

Wiring (see README.md): Omashiki containers never talk to this process
directly. They talk to the Omashiki gateway, which forwards to the `base_url`
of the credential named by the environment
(`Omashiki.Gateway.Providers.OpenaiCompat.upstream_base/1`). So this stub is
reached only by the host BEAM, over loopback.

Endpoints
    POST /v1/chat/completions   the measured surface (also served at any path
                                ending in `chat/completions`)
    GET  /v1/models             discovery, some clients probe it
    GET  /healthz               readiness for scripts
    GET  /__stats               request counters + peak observed concurrency
                                (`?reset=1` zeroes them)

Environment (CLI flags win over environment, which wins over defaults):
    LAT_MS       simulated inference latency, milliseconds  (default 1500)
    JITTER_PCT   +/- percentage applied to LAT_MS           (default 20)
    TURNS        tool-call turns before `finish_reason=stop`(default 0)
    PORT         listen port                                (default 8787)
    HOST         listen address                             (default 127.0.0.1)
    MODEL        model id echoed in responses               (default fake-model)
    SEED         RNG seed, for reproducible jitter          (default: random)
    SCENARIO     deterministic workload (default generic; python-hello is opt-in)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Bound the body we are willing to read. Agent prompts are large but not
# unbounded; the Omashiki contract itself caps a payload at 1 MiB.
MAX_BODY_BYTES = 32 * 1024 * 1024

DEFAULTS = {
    "lat_ms": 1500,
    "jitter_pct": 20,
    "turns": 0,
    "port": 8787,
    "host": "127.0.0.1",
    "model": "fake-model",
    "scenario": "generic",
}

PYTHON_HELLO_CONTENT = 'print("Hello, World!")\n'


class ScenarioConfigurationError(ValueError):
    """The request's tools cannot support the selected deterministic scenario."""


class Settings:
    """Resolved knobs, shared read-only by every handler thread."""

    def __init__(self, lat_ms, jitter_pct, turns, model, rng_seed=None, scenario="generic"):
        self.lat_ms = max(0, int(lat_ms))
        self.jitter_pct = max(0, min(100, int(jitter_pct)))
        self.turns = max(0, int(turns))
        self.model = model
        self.scenario = scenario
        self._rng = random.Random(rng_seed)
        self._rng_lock = threading.Lock()

    def sleep_seconds(self) -> float:
        """LAT_MS with symmetric jitter. Jitter matters: a fixed sleep makes
        every attempt finish in lockstep, which is not what a provider does and
        hides scheduler contention behind a neat staircase."""
        if self.jitter_pct == 0:
            return self.lat_ms / 1000.0
        spread = self.lat_ms * self.jitter_pct / 100.0
        with self._rng_lock:
            offset = self._rng.uniform(-spread, spread)
        return max(0.0, (self.lat_ms + offset) / 1000.0)


class Stats:
    """Counters, including the peak of simultaneously in-flight requests.

    Peak concurrency is the whole reason this stub exists, so it is measured
    here rather than inferred from wall-clock on the client side.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.reset()

    def reset(self):
        with self._lock:
            self.total = 0
            self.completions = 0
            self.tool_call_turns = 0
            self.stops = 0
            self.in_flight = 0
            self.peak_in_flight = 0
            self.active_markers = set()
            self.job_markers = set()
            self.job_marker_peak = 0
            self.started_at = time.time()

    def enter(self, marker: str | None = None) -> None:
        with self._lock:
            self.total += 1
            self.in_flight += 1
            if self.in_flight > self.peak_in_flight:
                self.peak_in_flight = self.in_flight
            if marker:
                self.active_markers.add(marker)
                self.job_markers.add(marker)
                if len(self.active_markers) > self.job_marker_peak:
                    self.job_marker_peak = len(self.active_markers)

    def leave(self, *, finish_reason: str | None, marker: str | None = None) -> None:
        with self._lock:
            self.in_flight -= 1
            if marker:
                self.active_markers.discard(marker)
            if finish_reason is not None:
                self.completions += 1
                if finish_reason == "tool_calls":
                    self.tool_call_turns += 1
                else:
                    self.stops += 1

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "requests": self.total,
                "completions": self.completions,
                "tool_call_turns": self.tool_call_turns,
                "stops": self.stops,
                "in_flight": self.in_flight,
                "peak_in_flight": self.peak_in_flight,
                "job_markers": sorted(self.job_markers),
                "job_marker_peak": self.job_marker_peak,
                "uptime_s": round(time.time() - self.started_at, 3),
            }


# ---------------------------------------------------------------------------
# Response construction
# ---------------------------------------------------------------------------


def prior_tool_turns(messages: list) -> int:
    """How many assistant turns in this conversation already asked for tools.

    HTTP is stateless and the engine replays the whole transcript every turn,
    so the transcript is the only honest place to read turn number from. Any
    server-side session counter would mis-attribute turns once more than one
    job is in flight.
    """
    count = 0
    for message in messages:
        if not isinstance(message, dict):
            continue
        if message.get("role") != "assistant":
            continue
        if message.get("tool_calls"):
            count += 1
    return count


def placeholder_for(name: str, schema: dict):
    kind = schema.get("type")
    if isinstance(kind, list):
        kind = next((k for k in kind if k != "null"), "string")

    if "enum" in schema and isinstance(schema["enum"], list) and schema["enum"]:
        return schema["enum"][0]
    if kind == "integer":
        return 1
    if kind == "number":
        return 1
    if kind == "boolean":
        return False
    if kind == "array":
        return []
    if kind == "object":
        return {}

    lowered = name.lower()
    if "path" in lowered or "file" in lowered:
        return "hello.txt"
    if "command" in lowered or "cmd" in lowered or "script" in lowered:
        return "echo 'hello world'"
    if "content" in lowered or "text" in lowered or "body" in lowered:
        return "hello world\n"
    if "pattern" in lowered or "query" in lowered:
        return "hello"
    return "hello world"


def synthesize_arguments(tool: dict) -> str:
    """Fill a tool's required parameters with schema-shaped placeholders.

    The stub does not know the harness's tool set ahead of time, so it reads the
    schema the engine sent. Emitting a tool call with arguments that fail the
    engine's own validation would end the run as a harness error and the load
    numbers would describe that bug instead of Omashiki.
    """
    function = tool.get("function") if isinstance(tool, dict) else None
    if not isinstance(function, dict):
        return "{}"
    schema = function.get("parameters")
    if not isinstance(schema, dict):
        return "{}"
    properties = schema.get("properties")
    if not isinstance(properties, dict):
        return "{}"

    required = schema.get("required")
    if not isinstance(required, list) or not required:
        required = list(properties)[:1]

    arguments = {}
    for name in required:
        prop = properties.get(name)
        arguments[name] = placeholder_for(name, prop if isinstance(prop, dict) else {})
    return json.dumps(arguments)


def python_hello_tool(tools: list) -> dict | None:
    """Return the write tool used by the opt-in Python hello scenario."""
    for tool in tools:
        function = tool.get("function") if isinstance(tool, dict) else None
        name = function.get("name", "") if isinstance(function, dict) else ""
        if isinstance(name, str) and name.lower() in {
            "write",
            "write_file",
            "writefile",
            "create_file",
        }:
            return tool
    raise ScenarioConfigurationError(
        "python-hello requires a write tool in the request's tool schema"
    )


def schema_accepts_string(schema: object, value: str) -> bool:
    """Check the string constraints needed by the deterministic call."""
    if not isinstance(schema, dict):
        return False
    if not isinstance(value, str):
        return False
    schema_type = schema.get("type")
    if isinstance(schema_type, str) and schema_type != "string":
        return False
    if isinstance(schema_type, list) and "string" not in schema_type:
        return False
    enum = schema.get("enum")
    if isinstance(enum, list) and value not in enum:
        return False
    if "const" in schema and schema["const"] != value:
        return False
    minimum = schema.get("minLength")
    if isinstance(minimum, int) and len(value) < minimum:
        return False
    maximum = schema.get("maxLength")
    if isinstance(maximum, int) and len(value) > maximum:
        return False
    pattern = schema.get("pattern")
    if isinstance(pattern, str):
        try:
            if re.search(pattern, value) is None:
                return False
        except re.error as exc:
            raise ScenarioConfigurationError(
                f"python-hello write schema has an invalid string pattern: {exc}"
            ) from exc
    return True


def python_hello_field(properties: dict, candidates: set[str]) -> str | None:
    for name in properties:
        if isinstance(name, str) and name.lower().replace("-", "_") in candidates:
            return name
    return None


def python_hello_arguments(tool: dict) -> str:
    """Build an exact, schema-valid hello.py write."""
    function = tool.get("function") if isinstance(tool, dict) else None
    schema = function.get("parameters") if isinstance(function, dict) else None
    properties = schema.get("properties") if isinstance(schema, dict) else None
    if not isinstance(properties, dict):
        raise ScenarioConfigurationError(
            "python-hello write tool has no object parameter schema"
        )

    path_name = python_hello_field(
        properties, {"path", "file_path", "filepath", "filename", "file_name"}
    )
    content_name = python_hello_field(properties, {"content", "contents", "text", "body"})
    if path_name is None or content_name is None:
        raise ScenarioConfigurationError(
            "python-hello write schema must expose both a file path and content field"
        )
    if not schema_accepts_string(properties[path_name], "hello.py"):
        raise ScenarioConfigurationError(
            f"python-hello write schema cannot carry the required path in {path_name!r}"
        )
    if not schema_accepts_string(properties[content_name], PYTHON_HELLO_CONTENT):
        raise ScenarioConfigurationError(
            f"python-hello write schema cannot carry the required exact content in {content_name!r}"
        )

    required = schema.get("required")
    names = list(required) if isinstance(required, list) else []
    for name in (path_name, content_name):
        if name not in names:
            names.append(name)
    intent_name = "intent" if "intent" in properties else None
    if intent_name is not None and intent_name not in names:
        names.append(intent_name)
    if "intent" in names and intent_name is None:
        raise ScenarioConfigurationError(
            "python-hello write schema requires intent but does not define it"
        )
    if not names:
        names = list(properties)[:1]

    arguments = {}
    for name in names:
        lowered = name.lower().replace("-", "_")
        prop = properties.get(name)
        if name == path_name:
            value = "hello.py"
        elif name == content_name:
            value = PYTHON_HELLO_CONTENT
        elif lowered == "intent":
            enum = prop.get("enum") if isinstance(prop, dict) else None
            if isinstance(enum, list) and enum:
                value = enum[0]
            elif isinstance(prop, dict) and "const" in prop:
                value = prop["const"]
            else:
                value = "create hello.py"
        else:
            value = placeholder_for(name, prop if isinstance(prop, dict) else {})
        if lowered == "intent" and not schema_accepts_string(prop, value):
            raise ScenarioConfigurationError(
                "python-hello write schema cannot carry a schema-valid intent"
            )
        arguments[name] = value
    return json.dumps(arguments)


def estimate_tokens(value) -> int:
    """~4 characters per token. Deliberately crude: the ledger only needs a
    plausible, non-zero, monotonic-with-size number, and inventing precision
    here would make usage reports look authoritative when they are not."""
    if value is None:
        return 0
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    return max(1, len(text) // 4)


def build_completion(body: dict, settings: Settings) -> tuple[dict, str]:
    messages = body.get("messages")
    messages = messages if isinstance(messages, list) else []
    tools = body.get("tools")
    tools = tools if isinstance(tools, list) else []
    model = body.get("model") or settings.model

    turn = prior_tool_turns(messages)
    scenario_tool = (
        python_hello_tool(tools) if settings.scenario == "python-hello" else None
    )
    if settings.scenario == "python-hello":
        wants_tool_call = scenario_tool is not None and turn == 0
    else:
        wants_tool_call = turn < settings.turns and bool(tools)

    if wants_tool_call:
        tool = scenario_tool or tools[turn % len(tools)]
        function = tool.get("function", {}) if isinstance(tool, dict) else {}
        arguments = (
            python_hello_arguments(tool)
            if scenario_tool is not None
            else synthesize_arguments(tool)
        )
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_{uuid.uuid4().hex[:24]}",
                    "type": "function",
                    "function": {
                        "name": function.get("name", "unknown"),
                        "arguments": arguments,
                    },
                }
            ],
        }
        finish_reason = "tool_calls"
        completion_text = message["tool_calls"][0]["function"]["arguments"]
    else:
        message = {
            "role": "assistant",
            "content": "Hello world. Done.",
        }
        finish_reason = "stop"
        completion_text = message["content"]

    prompt_tokens = sum(estimate_tokens(m.get("content")) for m in messages if isinstance(m, dict))
    prompt_tokens += estimate_tokens(tools) if tools else 0
    prompt_tokens = max(prompt_tokens, 1)
    completion_tokens = estimate_tokens(completion_text)

    response = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
            "prompt_tokens_details": {"cached_tokens": 0},
        },
    }
    return response, finish_reason


def stream_chunks(response: dict) -> list[bytes]:
    """Minimal SSE rendering.

    Omashiki's gateway forces `stream: false` before it calls upstream, so this
    path is unused in a load run. It exists so that pointing an engine straight
    at this stub, while debugging the wiring, does not fail in a confusing way.
    """
    choice = response["choices"][0]
    message = choice["message"]
    base = {
        "id": response["id"],
        "object": "chat.completion.chunk",
        "created": response["created"],
        "model": response["model"],
    }

    delta = {"role": "assistant"}
    if message.get("tool_calls"):
        delta["tool_calls"] = [
            {"index": i, **call} for i, call in enumerate(message["tool_calls"])
        ]
    else:
        delta["content"] = message.get("content") or ""

    frames = [
        {**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
        {
            **base,
            "choices": [{"index": 0, "delta": {}, "finish_reason": choice["finish_reason"]}],
            "usage": response["usage"],
        },
    ]
    out = [f"data: {json.dumps(frame)}\n\n".encode() for frame in frames]
    out.append(b"data: [DONE]\n\n")
    return out


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 keeps connections alive, which is what a pooled Elixir client
    # (Finch/Mint, behind the gateway) expects.
    protocol_version = "HTTP/1.1"
    server_version = "omashiki-fake-llm/1.0"

    settings: Settings
    stats: Stats
    verbose: bool

    def log_message(self, fmt, *args):
        if self.verbose:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- helpers ------------------------------------------------------------

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str, kind: str = "invalid_request_error") -> None:
        self._send(status, {"error": {"message": message, "type": kind}})

    def _read_body(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._error(400, "invalid Content-Length")
            return None
        if length > MAX_BODY_BYTES:
            self._error(413, "request body too large")
            return None
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._error(400, "request body is not valid JSON")
            return None
        if not isinstance(body, dict):
            self._error(400, "request body must be an object")
            return None
        return body

    @staticmethod
    def _is_completions(path: str) -> bool:
        return path.split("?", 1)[0].rstrip("/").endswith("chat/completions")

    # -- routes -------------------------------------------------------------

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/healthz":
            self._send(200, {"status": "ok"})
        elif path == "/__stats":
            snapshot = self.stats.snapshot()
            snapshot.update(
                lat_ms=self.settings.lat_ms,
                jitter_pct=self.settings.jitter_pct,
                turns=self.settings.turns,
            )
            if "reset=1" in self.path:
                self.stats.reset()
            self._send(200, snapshot)
        elif path in ("/v1/models", "/models"):
            self._send(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": self.settings.model,
                            "object": "model",
                            "created": int(time.time()),
                            "owned_by": "omashiki-loadtest",
                        }
                    ],
                },
            )
        else:
            self._error(404, f"unknown path: {path}", "not_found")

    def do_POST(self):
        if not self._is_completions(self.path):
            self._error(404, f"unknown path: {self.path}", "not_found")
            return

        body = self._read_body()
        if body is None:
            return

        marker_match = re.search(r"vm-e2e-marker-[A-Za-z0-9-]+", json.dumps(body))
        marker = marker_match.group(0) if marker_match else None
        self.stats.enter(marker)
        finish_reason = None
        try:
            # The sleep happens before any byte is written, so the client sees
            # one latency, not a trickle. It also holds the slot open, which is
            # what makes peak_in_flight meaningful.
            time.sleep(self.settings.sleep_seconds())
            response, finish_reason = build_completion(body, self.settings)

            if body.get("stream") is True:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                for chunk in stream_chunks(response):
                    self.wfile.write(chunk)
                self.close_connection = True
            else:
                self._send(200, response)
        except ScenarioConfigurationError as exc:
            # A bad scenario/tool pairing is a request-level configuration
            # failure. Return it explicitly without taking down the stub.
            try:
                self._error(500, str(exc), "scenario_configuration_error")
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True
        except (BrokenPipeError, ConnectionResetError):
            # Client vanished mid-flight (job cancelled, container torn down).
            # Not an error worth failing the stub over.
            self.close_connection = True
        finally:
            self.stats.leave(finish_reason=finish_reason, marker=marker)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # A load run reconnects constantly; without this a restart hits
    # "Address already in use" on the TIME_WAIT sockets from the last run.
    allow_reuse_address = True
    request_queue_size = 512


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(f"{name} must be an integer, got {raw!r}")


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="fake_llm.py",
        description="OpenAI-compatible LLM stub for Omashiki load tests.",
    )
    parser.add_argument("--host", default=os.environ.get("HOST", DEFAULTS["host"]))
    parser.add_argument("--port", type=int, default=env_int("PORT", DEFAULTS["port"]))
    parser.add_argument(
        "--lat-ms",
        type=int,
        default=env_int("LAT_MS", DEFAULTS["lat_ms"]),
        help="simulated inference latency in milliseconds",
    )
    parser.add_argument(
        "--jitter-pct",
        type=int,
        default=env_int("JITTER_PCT", DEFAULTS["jitter_pct"]),
        help="symmetric jitter applied to --lat-ms, in percent",
    )
    parser.add_argument(
        "--turns",
        type=int,
        default=env_int("TURNS", DEFAULTS["turns"]),
        help="tool-call turns to return before finish_reason=stop",
    )
    parser.add_argument("--model", default=os.environ.get("MODEL", DEFAULTS["model"]))
    parser.add_argument(
        "--scenario",
        choices=("generic", "python-hello"),
        default=os.environ.get("SCENARIO", DEFAULTS["scenario"]),
        help="deterministic workload to run",
    )
    seed_env = os.environ.get("SEED")
    parser.add_argument(
        "--seed",
        type=int,
        default=int(seed_env) if seed_env and seed_env.strip() else None,
        help="RNG seed for reproducible jitter",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="log every request")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    Handler.settings = Settings(
        args.lat_ms,
        args.jitter_pct,
        args.turns,
        args.model,
        rng_seed=args.seed,
        scenario=args.scenario,
    )
    Handler.stats = Stats()
    Handler.verbose = args.verbose

    try:
        server = Server((args.host, args.port), Handler)
    except OSError as exc:
        raise SystemExit(f"cannot bind {args.host}:{args.port}: {exc}")

    print(
        f"fake-llm listening on http://{args.host}:{args.port}  "
        f"lat_ms={args.lat_ms} jitter_pct={args.jitter_pct} "
        f"turns={args.turns} model={args.model}",
        flush=True,
    )
    print(
        f"  completions  POST http://{args.host}:{args.port}/v1/chat/completions\n"
        f"  stats        GET  http://{args.host}:{args.port}/__stats",
        flush=True,
    )

    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        print("\nshutting down", flush=True)
    finally:
        server.shutdown()
        server.server_close()

    print(json.dumps(Handler.stats.snapshot()), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
