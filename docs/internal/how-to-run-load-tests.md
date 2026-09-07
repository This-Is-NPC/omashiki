# How to run load tests

Use the local LLM stub to measure queue and container behavior without provider latency changes.
Use real providers only for a separate, explicit measurement.

## Before you start

Complete [development setup](how-to-set-up-development.md).
Use a disposable test repository and an API token.
Select capacity that the host can support.
A container count does not reserve physical memory or CPU in advance.

## 1. Configure the test environment

Use [loadtest.omashiki.toml](../../examples/loadtest.omashiki.toml) as the source for complete test declarations.
Copy only the tier and supporting declarations needed by this run.
Do not declare the same name twice across root and included files.
The `loadtest` tier uses jcode and the local stub.

Set `[limits].max_concurrent_containers` for the intended concurrency.
Set small, sufficient environment CPU and memory limits for the test instruction.
Restart the process after a machine-limit change.
Apply migrations before you compare capacity behavior.

## 2. Start the stub

In a separate terminal:

```bash
python3 .scripts/loadtest/fake_llm.py --port 8787 --lat-ms 1500 --turns 2
```

Keep this process running during the measurement.
The gateway credential must point to its reachable `/v1` URL.
The host-network test tier permits host loopback access.
Do not copy that network policy into an unrelated production environment.

## 3. Start the house

For separate database and server lifetimes:

```bash
mise run db-up
mise run migrate
```

Then, from `server/`, start Phoenix with the configured environment:

```bash
mise exec -- mix phx.server
```

Confirm that the test repository and environment appear in API discovery.
Use a bearer token even when local browser login is disabled.

## 4. Run a small measurement

From the repository root:

```bash
python3 .scripts/loadtest/drive.py -n 10 -c 2 \
  --repo omashiki --environment loadtest \
  --token "$OMASHIKI_API_TOKEN" \
  --json /tmp/omashiki-loadtest.json
```

Replace the repository and environment names with the test declarations.
Inspect terminal counts and errors before you increase concurrency.
Keep the source revision, resource settings, and report with the measurement.

## 5. Interpret the report

Record admitted jobs, terminal jobs, failures, latency, and peak concurrency separately.
A queue that reaches terminal state does not prove that every job succeeded.
Database pool exhaustion and Docker startup pressure can fail attempts during a burst.
Do not use a sampled active count as a physical capacity guarantee.

The historical 400-job run ended with 20 successes and 380 failures.
It demonstrated terminal-state recovery after a crash, not a 400-job success rate.
See [validation results](validation-results.md) for its exact conditions.

Stop the stub and test server after the run.
Retain the report if it will support a performance claim.
