# How to run tests

Use focused checks during development.
Use the complete local CI command for code changes before submission.

## Before you start

Complete [development setup](how-to-set-up-development.md).
Some commands need Docker, package downloads, or a real provider account.
Use an otherwise idle host when you compare timing results.

## 1. Select the test layer

| Command | Coverage |
| --- | --- |
| `mise run ci:server:fast` | ExUnit without integration or real-provider tests. |
| `mise run ci:server:integration` | Tests tagged `integration`, without real providers. |
| `mise run ci:server` | Full default server test selection. |
| `mise run ci:server:assets` | Tailwind and esbuild output, including the Git visibility check. |
| `mise run arch:check` | Static architecture checks and available reflection checks. |
| `mise run ci:server:vuln` | Hex dependency audit. |
| `mise run ci:server:cover` | Coverage report without a required coverage threshold. |

For one server test, run Mix from `server/` with the test environment.
For example:

```bash
cd server
MIX_ENV=test mix test test/omashiki/config/include_test.exs
```

Return to the repository root before you run the following mise commands.

## 2. Run local CI

```bash
mise run ci
```

The command runs `.scripts/ci.sh`.
The pre-push hook runs the same script.
Use the exit status to determine success.
Read warnings and ignored findings separately from that status.

## 3. Check a complete agent job

```bash
mise run e2e:overture
```

This separate E2E uses runc, jcode, and a deterministic local LLM stub.
The runner owns the stub process and checks cleanup.
The standard E2E is not part of local CI.

For the example handler:

```bash
python3 -m unittest examples/handler/test_github_issue_handler.py
```

These tests create a loopback HTTP server.
They do not contact a live tracker.

## Real providers

Real-provider tests are explicit choices:

```bash
mise run e2e:overture:runc:opencode
mise run e2e:overture:runc:claude
mise run e2e:overture:jcode:lmstudio
```

Configure provider access before you run the applicable command.
The LM Studio variant needs `OMASHIKI_LOCAL_LLM_BASE_URL`.
It uses jcode without host credential snapshots.

OpenCode and Claude tests use isolated credential copies.
Claude refresh changes remain in its test snapshot.
After a new host login, refresh that snapshot with:

```bash
python .scripts/overture_e2e.py validate claude
```

Use [distributed tests](how-to-run-distributed-tests.md) for manager and worker changes.
Use [load tests](how-to-run-load-tests.md) for capacity and durability measurements.
Record new results with their source revision in [validation results](validation-results.md).
