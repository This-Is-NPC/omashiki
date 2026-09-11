# How to run distributed tests

These tests check manager and worker execution.
They also check result delivery and isolation between houses.

## Before you start

Complete [development setup](how-to-set-up-development.md).
Provide Docker access and the host resources required by the selected test.
Do not run tests with overlapping ports or shared fixture files concurrently.

## Host and Compose tests

Select the required deployment:

| Command | Deployment and checks |
| --- | --- |
| `mise run e2e:host-worker` | Two host processes, host Docker, manager port `4011`, and fleet reports. |
| `mise run e2e:compose-worker` | Release images, HTTP enrollment, ports `4013` and `4014`. |
| `mise run e2e:two-houses` | Managers on `4021` and `4022`, worker enrollment on `4023`. |

The host-worker test reads `GET /api/v1/fleet` while the job runs.
It checks that the manager lists the real Docker container under the worker, with the job ID.
After the job, it checks that the removed container leaves the list.

The two-house test runs both houses through one worker.
It stops and restarts one house while it checks continued operation of the other.
It also checks house-specific results and persistent enrollment.

Run one applicable command from the repository root.
Check its final status and cleanup report.
Do not infer cross-host network behavior from a same-host run alone.

## VM tests

The VM harness needs libvirt, hardware virtualization, and the tools specified by `vm/manifest.toml`.
Preparation creates a reusable base image.
Runtime tests create disposable overlays from that base.

```bash
mise run e2e:vm:prepare
mise run e2e:vm:prepare:verify
mise run e2e:vm:runc
```

For the Kata variant:

```bash
mise run e2e:vm:kata
```

Kata additionally needs nested KVM support and the pinned runtime archive.
The matrix command runs both variants sequentially:

```bash
mise run e2e:vm:matrix
```

To retain the owned VM definitions and overlays for inspection:

```bash
vm/run.sh --runtime runc --keep-vms
```

The option applies only to that invocation.
The runner shuts down retained VMs and removes other run artifacts.
It validates ownership labels before cleanup.

The manifest defines topology, resources, ports, workload, delivery, and the runtime default.
The runner reports functional results, cleanup, and the runtime SLA.
The documented runtime SLA is ten minutes; preparation is a separate operation.
Capture the command output if you need a persistent report.

A forced `SIGKILL` cannot run cleanup handlers.
Inspect only the resources owned by that test invocation before manual cleanup.
See [distributed execution](distributed-execution.md) for the protocol invariants.
