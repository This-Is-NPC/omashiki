#!/usr/bin/env python3
"""
Load driver for Omashiki: submit N hello-world jobs, poll to completion, report.

What it measures
    Omashiki's admission and execution capacity under a fixed, boring workload.
    Point it at the fake LLM (`fake_llm.py`) so provider latency is a constant
    rather than the thing being measured.

Contract used (README.md at the repo root, `Omashiki.Jobs.Contract.V1`):
    POST /api/v1/jobs      envelope with schema_version=1 and a V2 payload
                           {"instruction": ..., "context": {...}}
                           -> 202 with {"data": {"id": ...}}
    GET  /api/v1/jobs/:id  status polling (blocked|queued|provisioning|running|
                           succeeded|failed|cancelled)
    GET  /api/v1/jobs/:id/result  terminal error code, for the breakdown

Auth: with `[auth] enabled = false` in omashiki.toml, `OmashikiWeb.Plugs.BearerAuth`
assigns the sole local operator -- but only for a loopback peer. Drive against
127.0.0.1, not the LAN address, or every request is a 401. Pass --token to run
against a bearer-auth deployment.

Stdlib only (urllib + threads), matching `.scripts/omashiki.py`; a load driver
that needs its own install is one more thing to debug at 2am.
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import pathlib
import statistics
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG_FILE = ROOT / "omashiki.toml"

TERMINAL = ("succeeded", "failed", "cancelled")
ACTIVE = ("provisioning", "running")
DEFAULT_INSTRUCTION = (
    "Create a file named hello.txt in the repository root containing exactly "
    "the text 'hello world', then commit it."
)


# ---------------------------------------------------------------------------
# Config / HTTP
# ---------------------------------------------------------------------------


def configured_port(default: int = 4010) -> int:
    """App port from omashiki.toml, same source `.scripts/omashiki.py` reads."""
    if not CONFIG_FILE.exists():
        return default
    with CONFIG_FILE.open("rb") as fh:
        return tomllib.load(fh).get("app", {}).get("port", default)


class ApiError(Exception):
    """A non-2xx response, carrying the contract's machine-readable code.

    `code` is what the report groups by -- `capacity_exhausted`,
    `invalid_request`, `unknown_environment` and friends all come from
    `OmashikiWeb.Api.JobsController.error/2`.
    """

    def __init__(self, status: int, code: str, message: str, details=None):
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message
        self.details = details or {}


class Client:
    def __init__(self, base_url: str, token: str | None, timeout: float):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        request.add_header("Accept", "application/json")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")

        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                payload = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                payload = {}
            error = payload.get("error") if isinstance(payload, dict) else None
            if isinstance(error, dict):
                raise ApiError(
                    exc.code,
                    error.get("code", f"http_{exc.code}"),
                    error.get("message", ""),
                    error.get("details"),
                ) from None
            raise ApiError(exc.code, f"http_{exc.code}", raw[:200].decode(errors="replace")) from None
        except urllib.error.URLError as exc:
            # Connection refused / DNS / TLS. Distinct from an API rejection:
            # collapsing them would hide "the server fell over" inside
            # "the server said no".
            raise ApiError(0, "transport_error", str(exc.reason)) from None
        except TimeoutError:
            raise ApiError(0, "client_timeout", f"no response in {self.timeout}s") from None


# ---------------------------------------------------------------------------
# Concurrency sampling
# ---------------------------------------------------------------------------


class Sampler(threading.Thread):
    """Peak concurrent attempts, from coherent server-side snapshots.

    Deliberately *not* aggregated from the per-job polls: those land at
    different instants, so a job seen "running" at t=0 would still be counted
    while another is first seen at t=0.4, and the peak would come out higher
    than any moment that ever existed. Overstating capacity is the one error
    this report must not make.

    So instead one thread asks the server for `GET /api/v1/jobs?status=running`
    and `?status=provisioning`, each of which is a single consistent query.

    Two honest limitations:

      * `Omashiki.Jobs.Api` caps `limit` at 100, so a run of more than 100 jobs
        can saturate a bucket and the reading becomes ">= 100".
      * an attempt that starts and finishes entirely between two samples is
        invisible, so the peak is a lower bound. Shrink --sample-interval, or
        read `[:omashiki, :runtime, :attempt, :complete]` telemetry server-side
        for the authoritative count.
    """

    LIST_LIMIT = 100

    def __init__(self, client: Client, interval: float):
        super().__init__(daemon=True)
        self.client = client
        self.interval = interval
        self._halt = threading.Event()
        self.peak_active = 0
        self.peak_at = None
        self.saturated = False
        self.samples: list[dict] = []
        self.errors = 0

    def stop(self) -> None:
        self._halt.set()

    def run(self) -> None:
        while not self._halt.is_set():
            self.sample_once()
            self._halt.wait(self.interval)
        # One last look, so a run that ends fast still has a data point.
        self.sample_once()

    def sample_once(self) -> None:
        counts = {}
        for status in ACTIVE:
            try:
                data = (
                    self.client.request(
                        "GET", f"/api/v1/jobs?status={status}&limit={self.LIST_LIMIT}"
                    )
                    or {}
                ).get("data") or []
            except ApiError:
                self.errors += 1
                return
            counts[status] = len(data)
            if len(data) >= self.LIST_LIMIT:
                self.saturated = True

        active = sum(counts.values())
        self.samples.append({"t": round(time.time(), 3), "active": active, **counts})
        if active > self.peak_active:
            self.peak_active = active
            self.peak_at = time.time()


# ---------------------------------------------------------------------------
# One job's lifecycle
# ---------------------------------------------------------------------------


class Outcome:
    __slots__ = (
        "index",
        "job_id",
        "status",
        "error_code",
        "submitted_at",
        "accepted_at",
        "finished_at",
        "queued_ms",
        "run_ms",
    )

    def __init__(self, index: int):
        self.index = index
        self.job_id = None
        self.status = None
        self.error_code = None
        self.submitted_at = None
        self.accepted_at = None
        self.finished_at = None
        self.queued_ms = None
        self.run_ms = None

    @property
    def wall_ms(self) -> float | None:
        if self.submitted_at is None or self.finished_at is None:
            return None
        return (self.finished_at - self.submitted_at) * 1000.0


def iso_ms(value) -> float | None:
    """Server ISO-8601 timestamp -> epoch seconds. Server clock, not ours."""
    if not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def run_job(index: int, args, client: Client, correlation_id: str) -> Outcome:
    outcome = Outcome(index)
    outcome.submitted_at = time.time()

    envelope = {
        "schema_version": 1,
        # Unique per job: a shared key would make Omashiki dedupe the run down
        # to one job and the report would be a lie.
        "idempotency_key": f"loadtest-{correlation_id}-{index:05d}",
        "correlation_id": correlation_id,
        "repo": args.repo,
        "environment": args.environment,
        "priority": args.priority,
        "payload": {
            "instruction": args.instruction,
            "context": {"loadtest": correlation_id, "index": str(index)},
        },
    }

    try:
        response = client.request("POST", "/api/v1/jobs", envelope)
    except ApiError as exc:
        outcome.status = "rejected"
        outcome.error_code = exc.code
        outcome.finished_at = time.time()
        return outcome

    data = response.get("data") or {}
    outcome.job_id = data.get("id")
    outcome.accepted_at = time.time()
    if not outcome.job_id:
        outcome.status = "rejected"
        outcome.error_code = "missing_job_id"
        outcome.finished_at = time.time()
        return outcome


    deadline = time.time() + args.job_timeout
    job = None
    while time.time() < deadline:
        time.sleep(args.poll_interval)
        try:
            job = (client.request("GET", f"/api/v1/jobs/{outcome.job_id}") or {}).get("data") or {}
        except ApiError as exc:
            # A transient poll failure is not a job failure; keep polling until
            # the deadline and only then give up.
            outcome.error_code = exc.code
            continue

        status = job.get("status")
        if status in TERMINAL:
            outcome.status = status
            outcome.finished_at = time.time()
            break
    else:
        outcome.status = "timeout"
        outcome.error_code = "driver_timeout"
        outcome.finished_at = time.time()
        return outcome

    # Server-side timings: queue wait vs. execution. Capacity saturation shows
    # up here as queue wait, not as a rejection -- see the README note on
    # `reserve_capacity!/0`.
    submitted = iso_ms(job.get("submitted_at")) or iso_ms(job.get("queued_at"))
    started = iso_ms(job.get("started_at"))
    finished = iso_ms(job.get("finished_at"))
    if submitted is not None and started is not None:
        outcome.queued_ms = max(0.0, (started - submitted) * 1000.0)
    if started is not None and finished is not None:
        outcome.run_ms = max(0.0, (finished - started) * 1000.0)

    if outcome.status != "succeeded":
        try:
            result = (
                client.request("GET", f"/api/v1/jobs/{outcome.job_id}/result") or {}
            ).get("data") or {}
            error = result.get("error")
            if isinstance(error, dict):
                outcome.error_code = error.get("code") or error.get("error_code") or "unknown"
            elif isinstance(error, str):
                outcome.error_code = error
            else:
                outcome.error_code = outcome.error_code or f"{outcome.status}_no_error"
        except ApiError as exc:
            outcome.error_code = outcome.error_code or exc.code

    return outcome


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def percentile(values: list[float], fraction: float) -> float | None:
    """Nearest-rank percentile: the smallest observed value at or above the
    rank. No interpolation -- with 100 samples an interpolated p95 invents a
    number that no job actually experienced."""
    if not values:
        return None
    ordered = sorted(values)
    rank = math.ceil(fraction * len(ordered))
    rank = min(max(rank, 1), len(ordered))
    return ordered[rank - 1]


def fmt_ms(value) -> str:
    if value is None:
        return "-"
    if value >= 1000:
        return f"{value / 1000.0:8.2f}s"
    return f"{value:8.0f}ms"


def summarize(values: list[float]) -> dict:
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
        "min": min(values),
        "mean": statistics.fmean(values),
    }


def report(outcomes: list[Outcome], sampler: Sampler, args, elapsed: float) -> dict:
    by_status = Counter(o.status for o in outcomes)
    succeeded = by_status.get("succeeded", 0)
    rejected = [o for o in outcomes if o.status == "rejected"]
    capacity_rejections = [o for o in rejected if o.error_code == "capacity_exhausted"]
    errors = Counter(o.error_code for o in outcomes if o.error_code)

    wall = summarize([o.wall_ms for o in outcomes if o.status in TERMINAL])
    queued = summarize([o.queued_ms for o in outcomes])
    run = summarize([o.run_ms for o in outcomes])

    print()
    print("=" * 72)
    print(f"Omashiki load test  --  {args.jobs} jobs, concurrency {args.concurrency}")
    print("=" * 72)
    print(f"  target            {args.base_url}")
    print(f"  repo/environment  {args.repo} / {args.environment}")
    print(f"  wall clock        {elapsed:.1f}s")
    print()
    print("  submitted         %d" % len(outcomes))
    print("  succeeded         %d" % succeeded)
    print("  failed            %d" % by_status.get("failed", 0))
    print("  cancelled         %d" % by_status.get("cancelled", 0))
    print("  rejected          %d  (never admitted)" % len(rejected))
    print("  driver timeout    %d  (> --job-timeout %ss)" % (by_status.get("timeout", 0), args.job_timeout))
    print()

    if capacity_rejections:
        print("  !! CAPACITY EXHAUSTED: %d job(s) rejected with 429 capacity_exhausted." % len(capacity_rejections))
        print("     The global execution_capacity row could not be reserved.")
        print("     See README.md -- the DB CHECK pinning capacity to 8 must be gone")
        print("     and [limits] max_concurrent_containers raised past --concurrency.")
        print()

    print("  wall clock per job (submit -> terminal)")
    print("    p50 %s   p95 %s   max %s" % (fmt_ms(wall.get("p50")), fmt_ms(wall.get("p95")), fmt_ms(wall.get("max"))))
    print("  queue wait (submitted_at -> started_at, server clock)")
    print("    p50 %s   p95 %s   max %s" % (fmt_ms(queued.get("p50")), fmt_ms(queued.get("p95")), fmt_ms(queued.get("max"))))
    print("  execution (started_at -> finished_at, server clock)")
    print("    p50 %s   p95 %s   max %s" % (fmt_ms(run.get("p50")), fmt_ms(run.get("p95")), fmt_ms(run.get("max"))))
    print()
    saturation = " (>= list limit 100; raise --jobs awareness)" if sampler.saturated else ""
    print(
        "  peak concurrent attempts  %d%s  (server snapshot every %.2fs; lower bound)"
        % (sampler.peak_active, saturation, args.sample_interval)
    )
    print()

    if errors:
        print("  error breakdown by code")
        for code, count in errors.most_common():
            print("    %-28s %d" % (code, count))
    else:
        print("  error breakdown by code: none")
    print("=" * 72)

    return {
        "target": args.base_url,
        "repo": args.repo,
        "environment": args.environment,
        "jobs": args.jobs,
        "concurrency": args.concurrency,
        "ramp_s": args.ramp,
        "elapsed_s": elapsed,
        "counts": dict(by_status),
        "capacity_exhausted": len(capacity_rejections),
        "peak_concurrent_attempts": sampler.peak_active,
        "peak_concurrent_saturated_list_limit": sampler.saturated,
        "concurrency_samples": sampler.samples,
        "wall_ms": wall,
        "queue_wait_ms": queued,
        "execution_ms": run,
        "errors": dict(errors),
        "jobs_detail": [
            {
                "index": o.index,
                "job_id": o.job_id,
                "status": o.status,
                "error_code": o.error_code,
                "wall_ms": o.wall_ms,
                "queued_ms": o.queued_ms,
                "run_ms": o.run_ms,
            }
            for o in outcomes
        ],
    }


# ---------------------------------------------------------------------------
# Preflight + main
# ---------------------------------------------------------------------------


def preflight(client: Client, args) -> None:
    """Fail before submitting 100 jobs, not after.

    Everything checked here produces a confusing per-job error later: a dead
    server looks like 100 transport errors, a missing environment looks like
    100 `unknown_environment` rejections.
    """
    try:
        client.request("GET", "/api/v1/health")
    except ApiError as exc:
        raise SystemExit(f"preflight: {args.base_url}/api/v1/health failed: {exc}")

    try:
        environments = (client.request("GET", "/api/v1/environments") or {}).get("data") or []
    except ApiError as exc:
        raise SystemExit(f"preflight: cannot list environments ({exc}); is auth disabled and the peer loopback?")

    names = [e.get("name") for e in environments]
    if args.environment not in names:
        raise SystemExit(
            f"preflight: environment {args.environment!r} is not registered. "
            f"Known: {', '.join(n for n in names if n) or '(none)'}. "
            "Paste the stanza from .scripts/loadtest/README.md into omashiki.toml and restart."
        )

    try:
        repositories = (client.request("GET", "/api/v1/repositories") or {}).get("data") or []
    except ApiError:
        return
    repo_names = [r.get("name") for r in repositories]
    if repo_names and args.repo not in repo_names:
        raise SystemExit(
            f"preflight: repository {args.repo!r} is not registered. "
            f"Known: {', '.join(n for n in repo_names if n)}"
        )

    environment = next((e for e in environments if e.get("name") == args.environment), {})
    timeout_ms = environment.get("timeout_ms")
    if isinstance(timeout_ms, int) and timeout_ms > args.job_timeout * 1000:
        print(
            f"note: environment timeout_ms={timeout_ms} exceeds --job-timeout "
            f"{args.job_timeout}s; the driver will give up before Omashiki does.",
            file=sys.stderr,
        )


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="drive.py",
        description="Submit N hello-world jobs to Omashiki and report capacity metrics.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("-n", "--jobs", type=int, default=100, help="number of jobs to submit")
    parser.add_argument(
        "-c", "--concurrency", type=int, default=0,
        help="jobs in flight at once (0 = same as --jobs, i.e. all at once)",
    )
    parser.add_argument(
        "--ramp", type=float, default=0.0,
        help="seconds over which to spread submissions (0 = as fast as possible)",
    )
    parser.add_argument("--base-url", default=None, help="default: http://127.0.0.1:<omashiki.toml app.port>")
    parser.add_argument("--token", default=None, help="bearer token; omit when [auth] enabled = false")
    parser.add_argument("--repo", default="omashiki")
    parser.add_argument("--environment", default="loadtest")
    parser.add_argument("--priority", type=int, default=1, choices=range(0, 4))
    parser.add_argument("--instruction", default=DEFAULT_INSTRUCTION)
    parser.add_argument("--poll-interval", type=float, default=1.0, help="seconds between status polls per job")
    parser.add_argument(
        "--sample-interval", type=float, default=0.5,
        help="seconds between server-wide snapshots used for peak concurrency",
    )
    parser.add_argument("--job-timeout", type=float, default=600.0, help="seconds before the driver gives up on a job")
    parser.add_argument("--http-timeout", type=float, default=30.0, help="per-request HTTP timeout")
    parser.add_argument("--json", dest="json_out", default=None, help="write the full report to this path")
    parser.add_argument("--skip-preflight", action="store_true")
    args = parser.parse_args(argv)

    if args.jobs < 1:
        parser.error("--jobs must be >= 1")
    if args.concurrency <= 0:
        args.concurrency = args.jobs
    args.concurrency = min(args.concurrency, args.jobs)
    if args.base_url is None:
        args.base_url = f"http://127.0.0.1:{configured_port()}"
    return args


def main(argv=None) -> int:
    args = parse_args(argv)
    client = Client(args.base_url, args.token, args.http_timeout)

    if not args.skip_preflight:
        preflight(client, args)

    correlation_id = f"loadtest-{uuid.uuid4().hex[:12]}"
    # Spacing between submissions. Ramping matters when the question is
    # "does admission survive a burst" vs. "does execution survive saturation".
    stagger = (args.ramp / args.jobs) if args.ramp > 0 else 0.0
    gate = threading.Lock()
    next_slot = [time.time()]

    def worker(index: int) -> Outcome:
        if stagger > 0:
            with gate:
                due = next_slot[0]
                next_slot[0] = due + stagger
            delay = due - time.time()
            if delay > 0:
                time.sleep(delay)
        return run_job(index, args, client, correlation_id)

    print(
        f"driving {args.jobs} jobs at concurrency {args.concurrency} "
        f"(ramp {args.ramp}s) against {args.base_url} "
        f"[{args.repo}/{args.environment}] correlation_id={correlation_id}",
        flush=True,
    )

    sampler = Sampler(client, args.sample_interval)
    sampler.start()

    started = time.time()
    outcomes: list[Outcome] = []
    done = 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        # as_completed, not map: map yields in submission order, so a slow
        # job 0 would hide the progress of the 99 behind it.
        futures = [pool.submit(worker, index) for index in range(args.jobs)]
        for future in as_completed(futures):
            outcome = future.result()
            outcomes.append(outcome)
            done += 1
            print(
                f"  [{done:>4}/{args.jobs}] {outcome.status or '?':<10} "
                f"{(outcome.job_id or '-')[:8]:<8} "
                f"{fmt_ms(outcome.wall_ms)} "
                f"{outcome.error_code or ''}",
                flush=True,
            )
    elapsed = time.time() - started
    sampler.stop()
    sampler.join(timeout=args.http_timeout + args.sample_interval)

    outcomes.sort(key=lambda o: o.index)
    payload = report(outcomes, sampler, args, elapsed)

    if args.json_out:
        path = pathlib.Path(args.json_out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nreport written to {path}")

    failed = payload["counts"].get("succeeded", 0) != args.jobs
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
