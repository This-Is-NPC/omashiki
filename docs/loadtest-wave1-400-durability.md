# Load test — Wave 1 durability at 400 jobs

Reference measurement for task **2809**: whether the Wave 1 dispatch-durability
fixes hold at 400-job scale with the fake-LLM stub. Re-take this file — do not
edit it in place — when the tier config, pool sizing, or harness changes.

**Taken:** 2026-08-27  
**Baseline commit:** `e9368a5` (worktree `task/2809`, base for measurement)  
**Host:** single developer workstation. Postgres in `server-db-1` on port 5442.  
**Runtime repo:** `/home/howl/Projects/person/omashiki` (main tree — agent
containers require a real git worktree; the task worktree is docs/commits only).  
**Harness:** `.scripts/loadtest/drive.py` + `.scripts/loadtest/fake_llm.py`
(`LAT_MS=1500`, `TURNS=0`).  
**Tier:** fake-LLM appendix from `.scripts/loadtest/README.md` pasted into local
`omashiki.toml` only (not committed). Local `max_concurrent_containers = 400`
in the same pasted block.  
**Env:** `.omashiki/loadtest.env` (`POOL_SIZE=200`, `OBAN_SCHEDULER_LIMIT=400`,
`OMASHIKI_LLM_GATEWAY_BASE_URL=http://127.0.0.1:4010`), chmod 600.  
**Run:** `drive.py -n 400 -c 400 --environment loadtest`  
`correlation_id=loadtest-9e3b4153d9cc`. Drive disconnected early; all 400 jobs
were admitted and the queue was polled to drain via DB (`jobs` status counts).

**Original debt (jcode, 400 jobs):** 109 Oban jobs discarded with job rows
stranded in `queued`; peak 116 concurrent containers; 79/80 pool connections
pinned by a row-lock convoy.

## Five numbers

| # | metric | result | pass |
|---|--------|--------|------|
| 1 | Job rows in a non-terminal state after the queue drains | **0** | yes |
| 2 | Oban `discarded` rows whose `job_id` still has a non-terminal job row | **0** | yes |
| 3 | Peak pool checkout vs `POOL_SIZE` | **200 / 200** | yes (at ceiling, no checkout errors) |
| 4 | Peak concurrent containers vs 116 baseline | **289 / 116** | informational |
| 5 | >100-row orphan sweep batch path exercised; converged | **no**; **yes** (all 400 terminal ~51s post-burst) | n/a / yes |

### How each number was taken

1. `SELECT count(*) FROM jobs WHERE status NOT IN ('succeeded','failed','cancelled');`
   after the last provisioning stragglers cleared (~10s after the main wave).

2. Join `jobs` to `oban_jobs` on `args->>'job_id'`, filter
   `worker = 'Omashiki.Jobs.DispatchWorker'`, `state = 'discarded'`, job status
   not terminal.

3. Ecto pool saturation from server log during the burst: minimum `idle=0.0ms`,
   maximum `queue=965.2ms`, no `connection not available` / `too many clients`
   lines. `POOL_SIZE=200` from `.omashiki/loadtest.env`. (The
   `pool_monitor.py` sidecar did not persist — it only writes on `SIGINT`; use
   log-derived pool saturation for this take.)

4. Peak `provisioning` + `running` job rows sampled every 10s during drain
   (`peak_active=289`). Baseline 116 from the pre-fix jcode 400-job run cited
   in task 2809.

5. `SELECT count(*) FROM job_events WHERE type = 'job.cancelled' AND
   data->>'error_code' = 'orphaned_dispatch';` → 0. No queued-without-dispatch
   backlog exceeded the `@orphan_batch_size 100` cancel path. Queue converged:
   397 `failed`, 7 `succeeded`, 0 non-terminal.

### Terminal breakdown

| status | count |
|--------|------:|
| failed | 397 |
| succeeded | 7 |

Job success rate is **not** an acceptance criterion; failures are OpenCode harness
`attempt_failed` against the stub, not dispatch stranding.

## Verdict

Criteria **1** and **2** are zero. Wave 1 dispatch durability fixes hold at
400-job scale for the fake-LLM tier. No follow-up task filed.
