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
| `test_fake_llm.py` | Stdlib-only unit tests for generic synthesis and the opt-in scenario. |

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
or every request is a 401. Pass `--token "$(cat .omashiki/loadtest.token)"`
anyway: drive without it returned `token_required` even on loopback.

---

## The `omashiki.toml` stanza

Paste this into `omashiki.toml`. **Plugin and model live on a preset.** The
environment only names that preset (`preset = "lt-stub"`) plus isolation,
image, sink, packages, and runtime limits. `harness =`, and `adapter` /
`runtime` on a preset, are boot errors.

The tracked sample does not ship these tiers: they raise
`[limits] max_concurrent_containers`, may name `${env:...}` credentials, and
are machine-specific. Paste the tier you want, raise `[limits]`, then start
Phoenix with `cd server && mix phx.server` after `mise run db-up`. Do not
`mise run up` — that recipe stops Postgres on exit.

Gateway tiers (stub, OpenRouter, local Qwen) put the model on the preset
*and* on the credential; the container never holds the provider key. Host-auth
tiers (OpenCode Go, Codex) put the model on the preset; credentials are
`[host_credentials.*]` origins.

```toml
[presets.lt-stub]
plugin = "jcode"
options = { timeout_ms = 120000, model = "fake-model" }

[credentials.loadtest-fake]
provider = "openai"
model = "fake-model"
api_key = "unused-by-the-stub"
base_url = "http://127.0.0.1:8787/v1"

[environments.loadtest]
preset = "lt-stub"
isolation = "docker"
image = "omashiki/agent-jcode:latest"
sink = "git"
packages = []
executables = ["git"]
credentials = ["loadtest-fake"]
caches = []
timeout_ms = 120000
network = "host"
mounts = []
post_steps = []
pre_steps = []

[environments.loadtest.policy]
mode = "off"

[environments.loadtest.resources]
cpus = 0.25
memory = "128MB"
pids = 128
```

`network = "restricted"` also works but resolves through
`:restricted_agent_network` / `OMASHIKI_AGENT_NETWORK_MODE` and needs a Docker
network you have already created; `host` is the shortest path to a first number.

Git-sink jobs also need `payload.title` or `payload.branch` (admission
`:task_branch_required`). `drive.py` sends a unique
`loadtest-{correlation_id}-{index:05d}` title per job.

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
    --token TOKEN       bearer; pass even on loopback if drive returns token_required
    --priority 0..3     default 1
    --poll-interval S   per-job status poll spacing (default 1.0)
    --sample-interval S server-wide concurrency snapshot spacing (default 0.5)
    --job-timeout S     driver gives up on a job after this (default 600)
    --json PATH         write the full report, including per-job rows
    --skip-preflight    skip the health/registry checks
```

Exit code is 0 only when every job succeeded, so it drops straight into a
script.

### Deterministic Python hello scenario

The generic stub remains the default. For an end-to-end jcode smoke test, opt
into the fake LLM scenario explicitly; it selects jcode's `write` tool and
returns one schema-valid call whose arguments create `hello.py` with exactly
`print("Hello, World!")` plus a newline. It stops after jcode reports the tool
result, regardless of `TURNS`.
If the request does not expose a compatible `write` schema, the stub returns
HTTP 500 with `scenario_configuration_error` instead of silently returning
`stop`.

In one terminal, start the controlled provider:

```bash
SCENARIO=python-hello LAT_MS=25 JITTER_PCT=0 \
  python3 .scripts/loadtest/fake_llm.py
```

In another terminal, run one jcode job through the configured `loadtest`
environment:

```bash
python3 .scripts/loadtest/drive.py \
  --jobs 1 --concurrency 1 --environment loadtest \
  --instruction 'Create hello.py containing exactly print("Hello, World!") followed by a newline, then commit it.' \
  --poll-interval 0.2 --sample-interval 0.2
```

The equivalent flag form is `fake_llm.py --scenario python-hello`. Do not set
`TURNS` for this scenario: it is intentionally a single write turn followed
by `stop`. The scenario is opt-in; unset `SCENARIO` to retain the generic
placeholder behavior and all existing defaults.

Run the local tests with:

```bash
python3 -m unittest discover -s .scripts/loadtest -p 'test_*.py'
```

`--concurrency` bounds jobs in flight; `--ramp` spreads *submission* over a
window. They answer different questions: concurrency asks "can execution hold N
at once", ramp asks "does admission survive a burst".

Each job gets a unique `idempotency_key`. A shared one would make Omashiki
dedupe the run down to a single job and the report would be a lie. Git-sink
jobs also get a unique `payload.title` so admission can name the task branch.

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

Stub-only checks on this machine:

* `fake_llm.py` does not serialize — plus `peak_in_flight` from the stub's
  own `/__stats` confirming the client-side numbers.
* Turn sequencing: `TURNS=2` returns exactly two `finish_reason: "tool_calls"`
  responses and then `"stop"`; arguments are synthesized from the request's
  tool schema (`{"command": "echo 'hello world'"}` for a `bash` tool,
  `{"filePath": …, "content": …}` for a write tool).
* Jitter: `LAT_MS=100 JITTER_PCT=20` measured 81–118 ms over 12 requests.
* `drive.py` against a throwaway Omashiki-shaped HTTP stand-in (percentiles,
  error breakdown, `capacity_exhausted` banner, `--json`, preflight failures).

Live matrix, 2026-08-27, post-cut presets only (reports in `.temp/lt-*.json`,
gitignored). Phoenix on `:4010`. Every job succeeded.

| env | n / c | wall | peak |
| --- | --- | --- | --- |
| `loadtest` (stub / jcode) | 100 / 100 | 53.5s | 105 |
| `lt-opencode-go` | 20 / 20 | 117.9s | 22 |
| `lt-openrouter` | 20 / 20 | 94.0s | 23 |
| `lt-codex` (`gpt-5.6-luna`, low) | 20 / 20 | 39.4s | 37 |
| `lt-qwen` (OpenCode / llama.cpp) | 10 / 2 | 1475.7s | 3 |
| `lt-jcode` (same Qwen) | 10 / 2 | 626.1s | 3 |

Subscriptions stay at 20. llama.cpp serializes: D/E at `-c 100` hit
`--job-timeout 600`. Drive them at `-n 10 -c 2 --job-timeout 900`.

---

## Appendix — the tier stanzas

These live here, not in the tracked `omashiki.toml`, for the reason stated at
the top of "The `omashiki.toml` stanza". Paste the tier you want. Each
environment **only references** a `[presets.lt-*]` declared next to it.

Five tiers, meant to be driven one at a time. All use `network = "host"`.
None declare `pre_steps`: `mise install` would measure the toolchain, not
Omashiki.

Subscriptions (OpenCode Go, OpenRouter, Codex) cap at **20 jobs**. Stub may
go to 100 (jcode 400 is the durability ceiling on the stub path). Local Qwen
(D/E) serializes in llama.cpp — drive `-n 10 -c 2 --job-timeout 900`, not
`-c 100`.

`[limits]` — the sample ships `8`. Raise it to at least the `-c` you drive, and
confirm the capacity-constraint migration is applied (see Prerequisites §1):

```toml
[limits]
max_concurrent_containers = 400
```

### Tier A — OpenCode subscription (`opencode-go`)

Host-auth path, no gateway and no key. The model is pinned on the preset.

```toml
[presets.lt-opencode-go]
plugin = "opencode"
options = { model = "opencode-go/glm-5.3-flash" }

[host_credentials.opencode-go]
kind = "opencode"
auth = "~/.local/share/opencode/auth.json"
config = "~/.config/omashiki/loadtest/opencode-go.json"

[environments.lt-opencode-go]
preset = "lt-opencode-go"
isolation = "docker"
image = "omashiki/agent:latest"
sink = "git"
packages = []
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

Gateway path: the container holds a job-bound token, never the key.
`z-ai/glm-5.3-flash` is a reasoning model — size `max_tokens` generously
(800 was ample for a trivial prompt) or jobs look like silent failures.

```toml
[presets.lt-openrouter]
plugin = "opencode"
options = { model = "z-ai/glm-5.3-flash" }

[credentials.openrouter]
provider = "openrouter"
model = "z-ai/glm-5.3-flash"
base_url = "https://openrouter.ai/api/v1"
api_key = "${env:OPENROUTER_API_KEY}"

[environments.lt-openrouter]
preset = "lt-openrouter"
isolation = "docker"
image = "omashiki/agent:latest"
sink = "git"
packages = []
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

Codex takes effort as `reasoning_effort` on the preset, not as a
`model:effort` slug. `codex-local` is declared in the tracked `omashiki.toml`.

```toml
[presets.lt-codex]
plugin = "codex"
options = { model = "gpt-5.6-luna", reasoning_effort = "low", timeout_ms = 600000 }

[environments.lt-codex]
preset = "lt-codex"
isolation = "docker"
image = "omashiki/agent-codex:latest"
sink = "git"
packages = []
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

### Tier D — local Qwen through OpenCode (gateway)

Export `OMASHIKI_LOCAL_LLM_BASE_URL` before starting Omashiki. The live E2E
used `qwen/qwen3.5-9b` at `http://192.168.0.200:1234/v1`. OpenCode takes the
gateway path when the environment names a gateway credential.

```toml
[presets.lt-qwen]
plugin = "opencode"
options = { model = "qwen/qwen3.5-9b" }

[credentials.qwen-local]
provider = "llamacpp"
model = "qwen/qwen3.5-9b"
base_url = "${env:OMASHIKI_LOCAL_LLM_BASE_URL}"
api_key = "unused-by-llama-server"

[environments.lt-qwen]
preset = "lt-qwen"
isolation = "docker"
image = "omashiki/agent:latest"
sink = "git"
packages = []
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
against ~675 MiB for OpenCode. It reuses Tier D's credential.

```toml
[presets.lt-jcode]
plugin = "jcode"
options = { timeout_ms = 600000, model = "qwen/qwen3.5-9b" }

[environments.lt-jcode]
preset = "lt-jcode"
isolation = "docker"
image = "omashiki/agent-jcode:latest"
sink = "git"
packages = []
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

Same as the stanza at the top of this file:

```toml
[presets.lt-stub]
plugin = "jcode"
options = { timeout_ms = 120000, model = "fake-model" }

[credentials.loadtest-fake]
provider = "openai"
model = "fake-model"
api_key = "unused-by-the-stub"
base_url = "http://127.0.0.1:8787/v1"

[environments.loadtest]
preset = "lt-stub"
isolation = "docker"
image = "omashiki/agent-jcode:latest"
sink = "git"
packages = []
executables = ["git"]
credentials = ["loadtest-fake"]
caches = []
timeout_ms = 120000
network = "host"
mounts = []
post_steps = []
pre_steps = []

[environments.loadtest.policy]
mode = "off"

[environments.loadtest.resources]
cpus = 0.25
memory = "128MB"
pids = 128
```
