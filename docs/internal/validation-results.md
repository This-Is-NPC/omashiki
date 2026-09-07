# Validation results

This page consolidates historical CI, load, and harness-cost measurements.
These records do not claim that the current checkout passed the same checks.
Use the linked procedures to collect new evidence.

For each new measurement, record the date, source revision, host, configuration, command, exit status, and limitations.
Keep old measurements identifiable when you add a new result.

## CI record: 2026-08-26

Source revision: `c1bfa3b8dfdd604d4102f8861b509772c69b0794`.
The original record described a clean Linux developer workstation with 24 scheduler-visible cores.
PostgreSQL used host port `5442`.

| Check | Exit | Recorded result |
| --- | --- | --- |
| Server, seed `747880` | 0 | 413 tests, 0 failures, 2 excluded; 15.1 seconds. |
| Server, seed `0` | 0 | 413 tests, 0 failures, 2 excluded; 15.4 seconds. |
| Assets | 0 | Tailwind and esbuild completed. |
| Dependency audit | 0 | Three cowlib advisories appeared in the ignore list. |
| Coverage | 0 | 56.96 percent total coverage; no required threshold. |
| Docker | 0 | Five images built with warm cache. |
| Architecture | 0 | Eleven static checks passed. |
| Formatting | 0 | No formatting difference. |

The record also identified missing reflection checks, tracked asset output, and untested gateway modules at that revision.
Those findings describe that revision only.
Check current source and tests before you classify any finding as still open.
An ignored advisory is not equivalent to an absent advisory.

### Historical image sizes

| Image | Original size | Later size recorded in the same document |
| --- | --- | --- |
| OpenCode | 7.21 GB | 699 MB after the Debian base change. |
| Claude Code | 8.41 GB | 1.1 GB after the Debian base change. |
| Codex | 8.46 GB | 1.09 GB after the Debian base change. |
| jcode | 484 MB | No later value recorded there. |
| Server | 85.3 MB | No later value recorded there. |

These values are historical measurements, not current image budgets.
Use the current Docker checks to inspect enforced budgets.

## Durability record: 2026-08-27

Reference task: `2809`. Baseline revision: `e9368a5`.
Run correlation: `loadtest-23c9b3d97374`.
The run used jcode, a local fake LLM, and 400 submitted jobs at concurrency 400.
The stub used 1500 ms latency and two tool turns.
The configuration used `POOL_SIZE=200`, `OBAN_SCHEDULER_LIMIT=400`, and a 90-second Docker timeout.

All 400 jobs were admitted.
The application stopped during Docker creation pressure.
After restart, stale-attempt recovery completed the drain.
The driver recorded 388.2 seconds.

| Metric | Recorded result |
| --- | --- |
| Nonterminal jobs after recovery | 0. |
| Discarded dispatch rows with nonterminal jobs | 0. |
| Successful jobs | 20. |
| Failed jobs | 380. |
| Failure categories | 251 stale attempts, 112 dispatch failures, 12 attempt failures, 5 runner crashes. |
| Peak running containers | 49. |
| Peak active capacity reservations | 354. |
| Containers present, including not started | 351. |
| Peak pool checkout | 200 of 200. |
| Orphan sweep above 100 rows | Not exercised. |

The earlier fault baseline had 109 discarded dispatch rows with stranded queued jobs.
The retake removed that terminal-state failure under its recorded conditions.
It did not prove successful execution at 400-container concurrency.
The old configuration vocabulary is obsolete and is not a current setup example.

## Provider comparison record

The former load-test guide recorded these runs under its local test configuration:

| Environment | Jobs / concurrency | Wall time | Reported peak |
| --- | --- | --- | --- |
| Stub with jcode | 100 / 100 | 53.5 seconds | 105 |
| OpenCode subscription | 20 / 20 | 117.9 seconds | 22 |
| OpenRouter | 20 / 20 | 94.0 seconds | 23 |
| Codex | 20 / 20 | 39.4 seconds | 37 |
| Local Qwen with OpenCode | 10 / 2 | 1475.7 seconds | 3 |
| Local Qwen with jcode | 10 / 2 | 626.1 seconds | 3 |

The source guide reported success for every job in these runs.
It did not supply a source revision beside this table.
Treat the numbers as historical observations, not reproducible performance guarantees.
The reported peak is a sampled driver metric, not the number of submitted jobs.

## Harness cost record

The task `2826` record compared CLI code after extracting `Omashiki.Harness.CliJson`.
Its comparison baseline was `6fe607e` and the earlier pi integration task `2821`.

| Module | Before | After |
| --- | --- | --- |
| Shared `cli_json.ex` | Not present | 213 lines. |
| `jcode.ex` | 233 lines | 138 lines. |
| `pi.ex` | 298 lines | 204 lines. |
| `codex.ex` | 277 lines | 210 lines. |
| `claude_code.ex` | 284 lines | 214 lines. |
| `open_code.ex` | 281 lines | 281 lines. |
| `open_code_http.ex` | 319 lines | 319 lines. |

The four CLI adapters and shared module totaled 979 lines after extraction.
The four adapters previously totaled 1092 lines.
Image work, registry entries, CI, tests, and integration work remained separate costs.
The record did not establish that a manifest would remove those costs.

## Current verification paths

Use [server and runtime tests](how-to-run-tests.md),
[distributed tests](how-to-run-distributed-tests.md), and
[load tests](how-to-run-load-tests.md) for new evidence.
The identity broker tests use a simulated GitHub service.
The Kata smoke does not establish complete workload compatibility.

## Documentation validation: 2026-09-07

Source baseline: `d350fe7`, with the documentation changes in the working tree.
The validation did not start a house or execute a provider job.

| Check | Result |
| --- | --- |
| Approved documentation paths | Matched the public and internal file layout. |
| Local Markdown targets and anchors | All checked targets resolved. |
| Shell, JSON, and TOML examples | Syntax checks passed. |
| Public OpenAPI operations | Matched the public router inventory. |
| Git request and task branch | Passed the executable V1, V2, and task-branch validators. |
| Non-Git requests | Files and none variants passed envelope validation without a repository. |
| Dependency example | The batch passed the executable dependency validator. |
| Reviewer configuration | Resolved against the single-node template. Image inspection used the test trust mode. |
| Prose sentence limits | No over-limit sentences in the checked procedural and descriptive paragraphs. |
| GIF and deployment diagrams | The GIF bytes and all five deployment topologies were preserved. |

The sentence check does not verify every vocabulary or grammar rule.
Documentation review also used the ASD-STE100 writing reference and the project technical terms.
