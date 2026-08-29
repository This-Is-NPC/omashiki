# Distributed VM E2E

`vm/run.sh` runs the complete two-node smoke test against the current working
tree from an explicitly prepared Fedora base. By default, every test-owned resource is disposable: the harness creates
or validates its VMs, runs the test, prints the JSON report to the terminal,
and removes the VMs and their overlays.

The harness:

- uses only the strictly validated `qemu:///system` domains
  `omashiki-node-1` and `omashiki-node-2`;
- leaves `test1`, `test2`, the Fedora base image, and all unrelated domains
  and volumes untouched;
- keeps source, generated configuration, logs, keys, and transport artifacts
  in private run-scoped directories under `/tmp`;
- runs core on the host and one worker plus fake provider in each VM;
- builds the current `agent-jcode` image once and loads it into both VMs;
- admits four independent jobs, verifies two active jobs per node, and checks
  assignment, overlap, runtime IDs, run-scoped labels, clean worktrees,
  canonical SHAs, output, capacity, and cleanup;
- removes processes, tunnels, containers, the database, image tags, temporary
  SSH authorization, guest runtime directories, domains, overlays, and host
  state on success, failure, or a handled signal;
- emits the complete schema-versioned report to stdout only after cleanup.

Prerequisites are checked before mutation: Docker, libvirt system access,
`~/.ssh/id_vms`, and the local PostgreSQL and agent image build inputs. Both
runtime variants require a current prepared base. A missing, stale, corrupted,
or unsafe base is reported immediately with instructions to run the explicit
preparation task rather than falling back to a slow guest bootstrap.

Prepare the base after changing `vm/manifest.toml`, the preparation scripts,
the preparation cloud-init, or the server dependency lock:

```bash
mise run e2e:vm:prepare
mise run e2e:vm:prepare:verify
```

Preparation validates the pinned Fedora and Kata SHA-256 values, provisions a
temporary owned VM, installs Docker and Kata, primes the Mix dependency cache,
smoke-tests runc and Kata, flattens the qcow2 image, and publishes a libvirt
volume only after all checks pass. Its fingerprint is content-addressed and a
second invocation is a verified no-op. A private pending journal lets the next
invocation recover an interrupted publication without treating a partial image
as ready. Preparation is intentionally outside the runtime SLA.

Run the disposable test from the repository root:

```bash
vm/run.sh --runtime runc
```

Use `vm/run.sh --runtime kata` for Kata, or `mise run e2e:vm:matrix` to run
both handlers sequentially. Each individual prepared-base run enforces a
600-second deadline and reports its measured SLA result in the final JSON.

Persist the owned VM definitions and qcow2 overlays for this invocation only:

```bash
vm/run.sh --runtime runc --keep-vms
```

`--keep-vms` is not stored in project configuration or the environment. It
still removes every other run artifact and leaves both VMs shut off. A later
run without the flag may reuse the validated VMs and will remove them when it
finishes.

`manifest.toml` is the source of topology, VM resources, libvirt base, network,
ports, workload, artifact delivery, and the default runtime variant. The
validated `--runtime runc|kata` option overrides only that variant for one run.
The runner validates the manifest before creating run state or acquiring the nonblocking lock.
The runtime IDs are `docker.runc.debian` and `docker.kata.debian`; the selected
ID is written into the generated environment. Kata mode additionally requires
the pinned Kata Containers 4.1.0 amd64 archive, nested KVM, and restricted
networking.

The pinned Kata archive used during preparation is kept in the private
`$XDG_CACHE_HOME/omashiki/vm-e2e` cache (or `~/.cache/omashiki/vm-e2e` when
`XDG_CACHE_HOME` is unset). Every use validates file ownership, permissions,
and the manifest SHA-256; downloads are written to a temporary file and moved
into place only after validation.

Each admitted job carries `payload.context.correlation_id` and the batch carries
the same run correlation. The server must propagate it to the
`omashiki.correlation_id` container label. The harness also requires the
`omashiki.job_scope_id` attempt label and records Docker `HostConfig.Runtime` for
every observed container. Missing, wrong, duplicate, or malformed ownership
metadata fails the run and prevents unsafe cleanup.

Long-running phases print their name, elapsed-time heartbeats, and completion
duration to stderr. Worker source transfer, image loading, and compilation run
in parallel across the two guests. Runtime cloud-init only supplies identity
and SSH access; package installation belongs exclusively to preparation. The
command exits zero only when the functional assertions, cleanup, and SLA pass.
No report or log is retained on disk; rerun the command to observe another
execution. `SIGINT`, `SIGTERM`, and `SIGHUP` enter cleanup. `SIGKILL` cannot be
handled and may require a subsequent run or manual cleanup of owned resources.
