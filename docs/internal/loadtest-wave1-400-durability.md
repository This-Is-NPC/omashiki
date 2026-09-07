# Load test — Wave 1 durability at 400 jobs

Reference measurement for task **2809**: whether the Wave 1 dispatch-durability
fixes hold at 400-job scale with the fake-LLM stub. Re-take this file — do not
edit it in place — when the tier config, pool sizing, or harness changes.

The previous take in this file (`loadtest-9e3b4153d9cc`, 397 failed / 7
succeeded) used OpenCode and is not the baseline this task is meant to beat.
This file records the jcode retake.

**Taken:** 2026-08-27
**Baseline commit:** `e9368a5` (worktree `task/2809` for docs; runtime on main tree)
**Host:** single developer workstation. Postgres in `server-db-1` on port 5442.
**Runtime repo:** the checkout's main tree, not a worktree. Mix started
from a git worktree makes job `.git` pointers resolve to the main repo, which
is not bind-mounted; the jcode entrypoint then dies `exit=128`
(`fatal: not a git repository`).
**Harness:** `.scripts/loadtest/drive.py` + `.scripts/loadtest/fake_llm.py`
(`--lat-ms 1500 --turns 2 --port 8787`).
**Tier (historical pre-runtime-cutover schema):** loadtest stanza pasted into
local `omashiki.toml` only (not committed): `[harnesses.jcode]`,
`[environments.loadtest]` `harness = "jcode"`,
`network = "host"`, `cpus = 0.25` / `memory = "128MB"`,
`max_concurrent_containers = 400`.
This declaration records the run and is not a current configuration example;
current environments select `preset` and `runtime = "docker.runc.debian"`, with
their plugin image resolved from `[runtimes.docker.runc.debian.images]`.
**Env:** `POOL_SIZE=200`, `OBAN_SCHEDULER_LIMIT=400`,
`OMASHIKI_DOCKER_TIMEOUT_MS=90000`,
`OMASHIKI_LLM_GATEWAY_BASE_URL=http://127.0.0.1:4010`.
**Run:** `drive.py -n 400 -c 400 --environment loadtest --token <api token>`
`correlation_id=loadtest-23c9b3d97374`. All 400 jobs were admitted. Mix's
application shut down under the Docker-create storm (~5 min); it was restarted
and `recover_stale` finished the drain. Drive wall clock **388.2s**.

**Original debt (jcode, 400 jobs):** 109 Oban jobs discarded with job rows
stranded in `queued`; peak 116 concurrent containers; 79/80 pool connections
pinned by a row-lock convoy.

## Five numbers

| # | metric | result | pass |
|---|--------|--------|------|
| 1 | Job rows in a non-terminal state after the queue drains | **0** | yes |
| 2 | Oban `discarded` rows whose `job_id` still has a non-terminal job row | **0** | yes |
| 3 | Peak pool checkout vs `POOL_SIZE` | **200 / 200** (15s checkout timeouts during the burst; `pg_stat_activity` active peaked **236** during crash overlap, backends **368**) | recorded; at ceiling |
| 4 | Peak concurrent containers vs 116 baseline | **49 running / 116** (capacity `active` peaked **354**; **351** jcode containers existed including `Created` and not started) | informational |
| 5 | >100-row orphan sweep batch path exercised; converged | **no**; **yes** (400/400 terminal after recover_stale) | n/a / yes |

### How each number was taken

1. `SELECT count(*) FROM jobs WHERE status NOT IN ('succeeded','failed','cancelled');`
   after drive finished and `execution_capacity.active = 0`. Result **0**.
   Scoped to this run: 20 `succeeded` + 380 `failed` = 400.

2. Join `jobs` to `oban_jobs` on `args->>'job_id'`, filter
   `worker = 'Omashiki.Jobs.DispatchWorker'`, `state = 'discarded'`, job status
   not terminal. Result **0**. No `discarded` rows at all at drain time
   (`cancelled=342`, `executing=333`, `completed=135`).

3. Sampler every 0.5s against `pg_stat_activity` for `omashiki_dev`, plus mix
   logs. First 120s (single live pool): `pg_active` max **200** = `POOL_SIZE`.
   Mix log: many `DBConnection.ConnectionError` … `queued and checked out the
   connection for longer than 15000ms`. After the application shutdown, a
   second BEAM overlapped leftover backends (`pg_total` 368).

4. `docker ps` filtered to `omashiki/agent-jcode:latest` every 0.5s: peak
   **49** running. Drive `peak_concurrent_attempts` **119** (list snapshot
   saturates at 100). `execution_capacity.active` peak **354**. After the mix
   shutdown, **351** jcode containers were removed (`Created` included).
   Baseline 116 is the pre-fix jcode 400-job peak cited in task 2809.

5. `SELECT count(*) FROM job_events WHERE type = 'job.cancelled' AND
   data->>'error_code' = 'orphaned_dispatch';` → **0**. Queued peaked at
   **324** but those rows moved into `provisioning` (dispatch existed), so the
   `@orphan_batch_size 100` cancel path was not exercised. Queue converged:
   0 non-terminal after recover_stale.

### Terminal breakdown (`loadtest-23c9b3d97374`)

| status | count | notes |
|--------|------:|-------|
| succeeded | 20 | fake_llm: 60 completions / 20 stops |
| failed | 380 | `stale_attempt` 251, `dispatch_failed` 112, `attempt_failed` 12, `runner_crash` 5 |

Job success rate is **not** an acceptance criterion. Failures here are Docker
create backlog, pool checkout timeouts, and `recover_stale` after the mix
application shutdown — not Oban-discard stranding.

### Observation (not criteria 1–2)

After the BEAM that owned the burst died, **333** `DispatchWorker` rows stayed
`executing` (oldest ~16 min) while their job rows were already terminal. That
is leftover Oban bookkeeping, not stranded `queued` jobs. No follow-up task
filed from this take; criteria 1 and 2 are zero.

## Verdict

Criteria **1** and **2** are zero. Wave 1 dispatch durability (no queued row
left behind a discarded Oban job) holds at 400-job jcode / fake-LLM scale.
No follow-up task filed.
