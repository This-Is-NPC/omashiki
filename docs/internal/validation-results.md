# Validation results

This page records how to collect evidence for the current checkout.
It also records current evidence limits.

## Record a measurement

For each measurement, record the date, source revision, host, configuration, command, exit status, and limitations.
Do not present a past measurement as current product behavior.

## Current verification paths

Use [server and runtime tests](how-to-run-tests.md),
[distributed tests](how-to-run-distributed-tests.md), and
[load tests](how-to-run-load-tests.md).

| Path | What it checks |
| --- | --- |
| `mise run ci` | Local CI for the current checkout. |
| `mise run e2e:overture` | A deterministic runc job with jcode and the local stub. |
| Distributed E2E | Manager and worker isolation, enrollment, and fleet reports. |
| Load-test tools | Queue and container behavior under a selected stub or provider. |
| Kata smoke | Runtime selection and Docker exec on the host. |

Use the exit status of the selected command.
Read warnings and ignored findings separately from that status.

## Evidence limits

| Area | Limit |
| --- | --- |
| Identity broker tests | They use a simulated GitHub service. |
| Kata smoke | It does not establish complete workload compatibility. |
| Load-test peak | A sampled active count is not a physical capacity guarantee. |
| Coverage | The coverage report has no required threshold. |
| Real providers | Those tests are explicit, separate commands. |

See [user limitations](../what-does-not-work.md) for product limits.
