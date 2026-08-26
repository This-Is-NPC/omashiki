# Omashiki load test

Tooling to run a 100-concurrent-agent load test where every job is a trivial
hello-world task.

The goal is to measure **Omashiki's** capacity, not a provider's. So the LLM is
replaced by a local stub with a fixed, configurable latency
(`fake_llm.py`), and the workload is a fixed instruction. Everything that
varies is something Omashiki owns: admission, capacity reservation, container
provisioning, worktree setup, teardown.

| file | what it is |
| --- | --- |
| `fake_llm.py` | OpenAI-compatible stub. Sleeps `LAT_MS`, optionally returns `TURNS` tool-call turns, reports plausible `usage`. |
| `drive.py` | Submits N jobs, polls to terminal, reports latency percentiles / error breakdown / peak concurrency. |

Both are Python 3 stdlib only — no installs beyond `mise install`, matching
`.scripts/omashiki.py` and `.scripts/overture_e2e.py`.

---

## Prerequisites — read this first

### 1. Global capacity must not be pinned to 8

`execution_capacity` is a single-row table. `Omashiki.Jobs.reserve_capacity!/0`
(`server/lib/omashiki/jobs.ex`) does a conditional `UPDATE … WHERE active <
capacity`; a zero-row update rolls the transaction back with
`:capacity_exhausted`.

The original schema pinned that row with a CHECK constraint
(`server/priv/repo/migrations/20260101000000_initial_schema.exs:186`,
`check: "capacity = 8 AND …"`), so `[limits] max_concurrent_containers` could
never move past 8. Above 8 concurrent, the run measures that constraint and
nothing else.

`server/priv/repo/migrations/20260826120000_relax_execution_capacity_check.exs`
(owned by another change, not this tooling) relaxes it to `capacity > 0`.
**Confirm it is applied before running anything above 8:**

```bash
mise run migrate

docker exec -it <postgres-container> psql -U postgres -d omashiki_dev \
  -c "\d+ execution_capacity"     # the CHECK must read capacity > 0
  -c "SELECT capacity, active FROM execution_capacity;"
```

If `capacity` still reads 8 after raising `[limits]`, the constraint is still
in place or the app has not restarted.

### 2. `[limits] max_concurrent_containers` must be raised

`Omashiki.Application` calls `Jobs.sync_capacity/0` on boot, which writes
`[limits].max_concurrent_containers` into the capacity row. For a 100-job run:

```toml
[limits]
max_concurrent_containers = 100
```

Note `set_capacity/1` clamps *up* to outstanding reservations but never down
below them, and requires a restart to take effect.

Also budget the host: 100 containers at `cpus = 2.0` / `memory = "2GB"` is
200 cores and 200 GB. Drop `[environments.loadtest.resources]` to something
like `cpus = 0.25` / `memory = "512MB"` for a hello-world workload, or the
kernel — not Omashiki — becomes the bottleneck.

### 3. Auth and loopback

`omashiki.toml` has `[auth] enabled = false`, and
`OmashikiWeb.Plugs.BearerAuth` then assigns the sole local operator — **but
only for a loopback peer.** Drive `http://127.0.0.1:4010`, not the LAN address,
or every request is a 401. Against a bearer deployment, pass `--token`.

---

## The `omashiki.toml` stanza

Paste this into `omashiki.toml` (I do not edit that file). It is
`[environments.opencode]` with two changes, both of which exist so the run
measures Omashiki:

* `pre_steps = []` — the stock environment runs `mise install --yes` with a
  600 s timeout on every attempt. Across 100 jobs that measures mise (and the
  shared cache's lock contention) rather than the orchestrator.
* `timeout_ms = 120000` — 2 minutes instead of 30. A hello-world job that has
  not finished in two minutes is wedged, and under load a 30-minute ceiling
  means a wedged attempt holds a capacity slot for the whole run.

```toml
[environments.loadtest]
harness = "opencode"
executables = ["mise", "git"]
credentials = []
caches = ["global"]
timeout_ms = 120000
network = "none"
mounts = []
post_steps = []
pre_steps = []

[environments.loadtest.policy]
mode = "off"

[environments.loadtest.resources]
cpus = 2.0
memory = "2GB"
pids = 256
```

### Two fields you will have to change to reach the stub

The stanza above is a faithful copy of `[environments.opencode]`, and that
environment as checked in **cannot reach any LLM at all**:

* `network = "none"` gives the container `NetworkMode=none` — no route to
  `host.docker.internal`, which is where
  `Omashiki.Gateway.base_url/0` points the engine.
* `credentials = []` means `ContainerManager.credential_for_environment/1`
  resolves nothing, so `Omashiki.Harness.OpenCode.prepare_gateway/5` never
  runs and no gateway `baseURL` is injected.

Containers never hold a provider key: the engine calls the Omashiki gateway,
and `Omashiki.Gateway.Providers.OpenaiCompat.upstream_base/1` forwards to the
credential's `base_url`. That is where `fake_llm.py` plugs in — over loopback,
from the host BEAM, so the stub never needs to be reachable from a container.

So to actually exercise the agent path, add a credential and let the container
out:

```toml
[credentials.loadtest-fake]
provider = "openai"
model = "fake-model"
api_key = "unused-by-the-stub"
base_url = "http://127.0.0.1:8787/v1"
```

…and in `[environments.loadtest]` set:

```toml
credentials = ["loadtest-fake"]
network = "host"
```

`network = "restricted"` also works but resolves through
`:restricted_agent_network` / `OMASHIKI_AGENT_NETWORK_MODE` and needs a Docker
network you have already created; `host` is the shortest path to a first number.

---

## Run order

```bash
# 0. one-time
mise install
mise run migrate                      # apply the capacity-constraint relaxation

# 1. edit omashiki.toml: paste the stanza above, raise [limits]

# 2. start the fake LLM (leave running)
LAT_MS=1500 TURNS=2 PORT=8787 python3 .scripts/loadtest/fake_llm.py

# 3. start Omashiki, in another shell — restart is required after any toml edit
mise run up

# 4. smoke test with 2 jobs before spending an hour on 100
python3 .scripts/loadtest/drive.py -n 2 --environment loadtest

# 5. the real run
python3 .scripts/loadtest/drive.py \
  -n 100 -c 100 \
  --environment loadtest \
  --json .temp/loadtest-100.json

# 6. confirm the stub really did serve them concurrently
curl -s http://127.0.0.1:8787/__stats
```

Between runs, `curl 'http://127.0.0.1:8787/__stats?reset=1'` zeroes the stub's
counters so `peak_in_flight` describes one run.

---

## `fake_llm.py`

`POST /v1/chat/completions`, plus `GET /v1/models`, `GET /healthz`, and
`GET /__stats`.

| env | default | meaning |
| --- | --- | --- |
| `LAT_MS` | `1500` | Simulated inference latency per request. |
| `JITTER_PCT` | `20` | Symmetric jitter on `LAT_MS`. Without it every attempt finishes in lockstep, which hides scheduler contention. |
| `TURNS` | `0` | Tool-call turns before `finish_reason: "stop"`. `TURNS=2` means two tool calls then a final answer — three round trips per job. |
| `PORT` | `8787` | Listen port. |
| `HOST` | `127.0.0.1` | Listen address. |
| `MODEL` | `fake-model` | Model id echoed back; must match the credential's `model`. |
| `SEED` | random | Fixes the jitter sequence for a reproducible run. |

Every knob also has a CLI flag (`--lat-ms`, `--turns`, …), which wins over the
environment.

Turn counting is stateless: the stub counts assistant messages that already
carry `tool_calls` in the transcript the engine replays. A server-side counter
would mis-attribute turns as soon as two jobs are in flight.

Tool-call arguments are synthesized from the schema the engine sends in
`tools`, filling each required property with a type-appropriate placeholder, so
the engine's own validation passes and the run does not end up measuring a
harness error.

`usage` is estimated at ~4 characters per token. Deliberately crude — the
ledger needs a plausible non-zero number, and more precision here would only
look authoritative.

**Concurrency.** `ThreadingHTTPServer` serves each connection on its own thread
and `time.sleep` releases the GIL, so N in-flight requests take ~`LAT_MS`, not
N × `LAT_MS`. `/__stats` reports `peak_in_flight` so this is checkable rather
than assumed. Measured on this machine at `LAT_MS=1000 JITTER_PCT=0`:

| concurrent requests | wall clock | if serialized | `peak_in_flight` |
| ---: | ---: | ---: | ---: |
| 20 | 1.020 s | 20 s | 20 |
| 100 | 1.045 s | 100 s | 100 |
| 150 | 1.045 s | 150 s | 150 |

---

## `drive.py`

```
-n, --jobs N            jobs to submit (default 100)
-c, --concurrency N     jobs in flight at once (default: same as --jobs)
    --ramp SECONDS      spread submissions over this window (default 0 = burst)
    --environment NAME  default "loadtest"
    --repo NAME         default "omashiki"
    --instruction TEXT  the hello-world instruction
    --base-url URL      default http://127.0.0.1:<omashiki.toml app.port>
    --token TOKEN       bearer token; omit when [auth] enabled = false
    --priority 0..3     default 1
    --poll-interval S   per-job status poll spacing (default 1.0)
    --sample-interval S server-wide concurrency snapshot spacing (default 0.5)
    --job-timeout S     driver gives up on a job after this (default 600)
    --json PATH         write the full report, including per-job rows
    --skip-preflight    skip the health/registry checks
```

Exit code is 0 only when every job succeeded, so it drops straight into a
script.

`--concurrency` bounds jobs in flight; `--ramp` spreads *submission* over a
window. They answer different questions: concurrency asks "can execution hold N
at once", ramp asks "does admission survive a burst".

Each job gets a unique `idempotency_key`. A shared one would make Omashiki
dedupe the run down to a single job and the report would be a lie.

### Metrics

**submitted / succeeded / failed / cancelled** — terminal job status from
`GET /api/v1/jobs/:id`.

**rejected** — never admitted. `POST /api/v1/jobs` returned non-2xx, so there
is no job to poll. Grouped by the error code from
`OmashikiWeb.Api.JobsController`.

**driver timeout** — still not terminal after `--job-timeout`. Says nothing
about Omashiki by itself; check whether the job was still `running` (slow) or
stuck in `queued` (starved).

**wall clock per job (p50 / p95 / max)** — submit → terminal, measured on the
driver's clock. The number a caller experiences. Percentiles are nearest-rank,
not interpolated: with 100 samples an interpolated p95 invents a number no job
actually experienced.

**queue wait (p50 / p95 / max)** — `submitted_at` → `started_at`, server clock.
**This is where capacity saturation shows up.** With `max_concurrent_containers
= 8` and 100 jobs, execution time stays flat and queue wait grows linearly.

**execution (p50 / p95 / max)** — `started_at` → `finished_at`, server clock.
Provisioning + agent + teardown. With the stub's latency fixed, growth here is
host contention (Docker, disk, worktrees), not the LLM.

**peak concurrent attempts** — the largest number of jobs simultaneously in
`provisioning` or `running`. Sampled by a dedicated thread hitting
`GET /api/v1/jobs?status=…`, which is one coherent server-side query.
Deliberately *not* aggregated from the per-job polls: those land at different
instants, so a job seen running at t=0 would still be counted while another is
first seen at t=0.4, and the peak would come out higher than any moment that
ever existed. Overstating capacity is the one error this report must not make.

Two honest limits: `Omashiki.Jobs.Api` caps `limit` at 100, so past 100 the
reading saturates (the report flags this); and an attempt that starts and
finishes entirely between two samples is invisible, so the number is a lower
bound. For the authoritative count, attach to the
`[:omashiki, :runtime, :attempt, :complete]` telemetry server-side (see below).

**error breakdown by code** — machine-readable codes, from submit rejections
and from `GET /api/v1/jobs/:id/result` for non-succeeded jobs.

### `capacity_exhausted`

Called out with its own banner in the report. Worth knowing exactly what it
means, because it is easy to over-read:

`:capacity_exhausted` originates in `Jobs.reserve_capacity!/0`, which is
reached from `claim_locked/4` — i.e. at **dispatch**, not at admission.
`Jobs.DispatchWorker.perform/1` catches it and returns `{:snooze, 1}`, so the
Oban job retries a second later.

So under normal saturation, jobs are **not rejected**. They queue, and the cost
appears as **queue wait**, not as a 429. A `capacity_exhausted` line in the
error breakdown means the API surface itself refused admission
(`JobsController` maps it to `429`), which is a much stronger signal — treat it
as "capacity accounting is wrong", not "the queue is busy".

### Server-side telemetry (optional, more precise)

The driver measures from outside. For per-attempt truth, attach a handler in an
IEx session on the running node:

```elixir
:telemetry.attach_many(
  "loadtest",
  [
    [:omashiki, :runtime, :attempt, :complete],
    [:omashiki, :runtime, :attempt, :cancel],
    [:omashiki, :runtime, :attempt, :heartbeat]
  ],
  fn event, measurements, metadata, _ ->
    IO.puts("#{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}")
  end,
  nil
)
```

`[:omashiki, :runtime, :attempt, :complete]` carries `duration_ms` and
`%{attempt_id:, outcome:}` where `outcome` is `"ok"` or `"error"`, emitted from
`Omashiki.Runtime.Attempt.finish/2`. Counting `complete` minus starts over time
gives an exact concurrency curve rather than a sampled one.

---

## What has and has not been validated

Validated on this machine:

* `fake_llm.py` does not serialize — the table above, plus `peak_in_flight`
  from the stub's own `/__stats` confirming the client-side numbers.
* Turn sequencing: `TURNS=2` returns exactly two `finish_reason: "tool_calls"`
  responses and then `"stop"`; arguments are synthesized from the request's
  tool schema (`{"command": "echo 'hello world'"}` for a `bash` tool,
  `{"filePath": …, "content": …}` for a write tool).
* Jitter: `LAT_MS=100 JITTER_PCT=20` measured 81–118 ms over 12 requests.
* `drive.py` end to end — submission, polling, `--ramp`, bounded
  `--concurrency`, percentile math, error breakdown, the `capacity_exhausted`
  banner, `--json` output, and all three preflight failure paths — against a
  throwaway Omashiki-shaped HTTP stand-in. With that stand-in capped at 8
  concurrent, the sampler reported peak concurrent attempts = 8, matching.

**Not** validated: a real end-to-end run. Nothing here has been pointed at a
live Omashiki with real Docker containers and a real OpenCode harness. In
particular these are untested and are the first things to check:

* whether OpenCode inside the container accepts the stub's synthesized tool
  calls and reaches a clean commit,
* whether `network = "host"` plus a `base_url` credential is enough for the
  gateway path end to end,
* how the host behaves at 100 concurrent containers,
* whether `timeout_ms = 120000` is generous enough for cold provisioning.

---

## Appendix — the tier stanzas

These live here, not in `omashiki.toml`, for the reason stated at the top of
"The `omashiki.toml` stanza": that file is the tracked sample every clone
starts from, and it should not ship five load-test environments, a
machine-specific config path, or a private LAN address. Paste the tier you
want, raise `[limits] max_concurrent_containers` to match, restart.

Five tiers, meant to be driven one at a time. All use `network = "host"`:
`"restricted"` collapses to `"none"` unless `OMASHIKI_AGENT_NETWORK_MODE` is
set, and every tier needs either a real route to the provider (host auth) or a
route back to the gateway on loopback.

None declare `pre_steps`: `mise install` would measure the toolchain, not
Omashiki.

`[limits]` — the sample ships `8`. Raise it to at least the `-c` you drive, and
confirm the capacity-constraint migration is applied (see Prerequisites §1):

```toml
[limits]
max_concurrent_containers = 400
```

### Tier A — OpenCode subscription (`opencode-go`)

Host-auth path, no gateway and no key: the model cannot be pinned from Omashiki
here, so it comes from a dedicated config origin that leaves the operator's own
`~/.config/opencode/opencode.json` untouched.

```toml
[host_credentials.opencode-go]
kind = "opencode"
auth = "~/.local/share/opencode/auth.json"
config = "~/.config/omashiki/loadtest/opencode-go.json"

[environments.lt-opencode-go]
harness = "opencode"
executables = ["git"]
credentials = ["opencode-go"]
caches = ["global"]
timeout_ms = 600000
network = "host"
mounts = []
pre_steps = []
post_steps = []

[environments.lt-opencode-go.policy]
mode = "off"

[environments.lt-opencode-go.resources]
cpus = 1.0
memory = "1GB"
pids = 256
```

### Tier B — OpenRouter, the gateway key path

Gateway path: the container holds a job-bound token, never the key. The key
itself stays in the environment because `omashiki.toml` is tracked by git —
`${env:VAR}` is resolved at load time and fails loudly when the variable is
unset.

The stealth model this tier used to pin is gone from both OpenCode and
OpenRouter, so pin one the account can actually reach; the tier is about the
key path, not about any one model.

```toml
[credentials.openrouter]
provider = "openrouter"
model = "a-model-this-account-can-reach"
base_url = "https://openrouter.ai/api/v1"
api_key = "${env:OPENROUTER_API_KEY}"

[environments.lt-openrouter]
harness = "opencode"
executables = ["git"]
credentials = ["openrouter"]
caches = ["global"]
timeout_ms = 600000
network = "host"
mounts = []
pre_steps = []
post_steps = []

[environments.lt-openrouter.policy]
mode = "off"

[environments.lt-openrouter.resources]
cpus = 0.5
memory = "1GB"
pids = 256
```

### Tier C — Codex with `gpt-5.6-luna` at low effort

Codex takes effort as `model_reasoning_effort`, not as a `model:effort` slug,
so it is a separate option rather than part of the model name.

```toml
[harnesses.codex-luna]
adapter = "codex"
runtime = "docker"
image = "omashiki/agent-codex:latest"
options = { model = "gpt-5.6-luna", reasoning_effort = "low", timeout_ms = 600000 }

[environments.lt-codex]
harness = "codex-luna"
executables = ["git"]
credentials = ["codex-local"]
caches = ["global"]
timeout_ms = 600000
network = "host"
mounts = []
pre_steps = []
post_steps = []

[environments.lt-codex.policy]
mode = "off"

[environments.lt-codex.resources]
cpus = 1.0
memory = "512MB"
pids = 256
```

`codex-local` is declared in the tracked `omashiki.toml`.

### Tier D — local Qwen2.5-Coder-1.5B-Instruct

The address is one specific private LAN box, so it stays in the operator's
environment rather than in the tracked file: `base_url` takes the same
`${env:VAR}` form as `api_key` and fails the boot by name when the variable is
unset. Export it before starting Omashiki, for example
`OMASHIKI_LOCAL_LLM_BASE_URL=http://<host>:8080/v1`.

Use the **instruct** model: the 0.5B GGUF is the *base* model, never emits a
stop token under the OpenCode system prompt, and generates until the slot
context is exhausted (29k tokens / 121 s per turn). The 1.5B instruct answers
the same prompt in 0.7 s with `finish_reason=stop`.

`llama-server` speaks OpenAI-compat; the gateway reaches it over the LAN and
the container only ever sees the gateway.

```toml
[credentials.qwen-local]
provider = "llamacpp"
model = "qwen2.5-coder-1.5b-instruct"
base_url = "${env:OMASHIKI_LOCAL_LLM_BASE_URL}"
api_key = "unused-by-llama-server"

[environments.lt-qwen]
harness = "opencode"
executables = ["git"]
credentials = ["qwen-local"]
caches = ["global"]
timeout_ms = 600000
network = "host"
mounts = []
pre_steps = []
post_steps = []

[environments.lt-qwen.policy]
mode = "off"

[environments.lt-qwen.resources]
cpus = 0.25
memory = "1GB"
pids = 256
```

### Tier E — jcode on the local server, the high-concurrency configuration

jcode is a static binary with no runtime: ~15 MiB resident per container
against ~675 MiB for OpenCode. That is what moves the memory ceiling from ~53
concurrent containers to a number CPU reaches first (~430 at the measured 0.028
cores per attempt).

It reuses Tier D's credential: jcode has no host-auth route, so it always
reaches the model through the gateway, and the gateway is what holds the local
server's address.

```toml
[harnesses.jcode]
adapter = "jcode"
runtime = "docker"
image = "omashiki/agent-jcode:latest"
options = { timeout_ms = 600000 }

[environments.lt-jcode]
harness = "jcode"
executables = ["git"]
credentials = ["qwen-local"]
caches = []
timeout_ms = 600000
network = "host"
mounts = []
pre_steps = []
post_steps = []

[environments.lt-jcode.policy]
mode = "off"

[environments.lt-jcode.resources]
cpus = 0.25
memory = "128MB"
pids = 128
```

### The fake-LLM tier

The stub tier from "The `omashiki.toml` stanza" above, with the two fields
already applied and resources dropped for a hello-world workload:

```toml
[credentials.loadtest-fake]
provider = "openai"
model = "fake-model"
api_key = "unused-by-the-stub"
base_url = "http://127.0.0.1:8787/v1"

[environments.loadtest]
harness = "opencode"
executables = ["mise", "git"]
credentials = ["loadtest-fake"]
caches = ["global"]
timeout_ms = 120000
network = "host"
mounts = []
post_steps = []
pre_steps = []

[environments.loadtest.policy]
mode = "off"

[environments.loadtest.resources]
cpus = 0.25
memory = "512MB"
pids = 256
```
