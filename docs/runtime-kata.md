# Kata Containers Runtime Backend

Design direction for a second execution backend that gives each sandbox its own
kernel without rewriting the mount and secret boundary. This is a **second
backend, not a replacement**: Docker stays the default.

Kata does not solve the microVM gaps in the filesystem and secret boundary — it
does not create them. It implements the containerd shim v2 interface and
registers as a Docker runtime class, so bind mounts, the read-only secret file,
and uid/gid ownership keep working. NFR-004 and NFR-007 survive without a
rewrite.

Status: **not implemented.** This document records the design, the code change
it actually requires, and the guarantees that must be re-verified.

## The Seam Already Exists

- `Omashiki.Runtime.ContainerManagerBehaviour` declares six callbacks, and
  `provision_result` already speaks `sandbox_id` rather than `container_id`,
  with optional `host`/`port` and a map `transport`.
- `Omashiki.Runtime.Capability` hands adapters only `transport`, `endpoint`,
  and `exec`. No Docker concept crosses that line.
- `runtime` is already a field of the harness profile
  (`harness/types.ex:4`), and `Omashiki.Runtimes.Runtime` already accepts
  `kata` as a valid kind (`runtimes/runtime.ex:22`).

Harness adapters do not change. `ContainerManager` keeps talking the Docker API
over the same Mint socket; what changes at the wire level is one `HostConfig`
field.

## Configuration

### Host

Register the runtime in `daemon.json` in shim v2 form — verify the exact shape
against the installed Docker version:

```json
{
  "runtimes": {
    "kata": { "runtimeType": "io.containerd.kata.v2" }
  }
}
```

Prerequisite: KVM available, either bare metal or nested virtualization.

Upstream is the monorepo at
<https://github.com/kata-containers/kata-containers>. The `kata-containers/
runtime`, `/agent`, `/proxy`, and `/shim` repositories were archived around
2020 and still rank high in search results; ignore them.

**Which version.** Release 4.0.0 rewrote the runtime from Go to Rust and made
`runtime-rs` the default. It is a new implementation, not a continuation of the
3.x line.

- **3.32.0** — Go runtime, mature. The default choice for a first spike.
- **4.1.0** — Rust runtime. The better medium-term target, but new enough that
  it should not be where the project discovers that virtio-fs broke NFR-004.

Validate the whole route on 3.32.0 first, then evaluate 4.x.

**VMM: Cloud Hypervisor**, the Kata default and the better performer. **Do not
use Firecracker as the backend** — it has no virtio-fs, only block devices,
which removes exactly the bind mounts that motivate this route.

### Omashiki

The declaration is one field:

```toml
[harnesses.opencode]
runtime = "kata"   # was: "docker"
```

**The code behind that field is not one field.** A kata profile loads clean and
then fails on the first job:

- `Omashiki.Runtimes.docker_image/1` matches only `kind: "docker"`
  (`runtimes.ex:9,16`). Every other kind falls through to the catch-all clause
  that returns `nil` (`runtimes.ex:23`).
- `ContainerManager.image_of/1` (`container_manager.ex:1320`) raises
  `ArgumentError` when image resolution yields `nil`, so every kata attempt
  dies at provision.
- Nothing catches this earlier. `Runtime.changeset/2` requires an image only
  when `kind == "docker"` (`runtimes/runtime.ex:44`), and
  `Harnesses.validate_launch_plan!/2` applies the same conditional
  (`harnesses.ex:188`). Boot validation passes; the failure surfaces per job.

The minimum code change before the TOML flag means anything:

1. Make image resolution kind-neutral, so a non-Docker kind still yields its
   OCI image.
2. Extend `Runtime.changeset/2` and `Harnesses.validate_launch_plan!/2` to
   require an image for `kata` as well, so a bad profile fails at boot rather
   than per attempt.
3. Pass `Runtime: "kata"` in the `HostConfig` map that `ContainerManager`
   builds.

## What Must Be Re-Verified

This is the part with real work in it. None of it is rewiring; all of it is
revalidating a guarantee.

### NFR-004 — Filesystem safety

Mounts arrive over virtio-fs instead of a direct bind mount. Re-test:

- [ ] The parent repository is genuinely read-only inside the guest
- [ ] Path-escape and symlink-component rejection still hold
- [ ] Repository owner uid/gid are preserved through virtio-fs
- [ ] Cache mounts (`/omashiki-cache/*`) keep the same semantics

### NFR-007 — Credential handling

- [ ] The host temporary file bind-mounted `:ro` under `/tmp`
      (`container_manager.ex:1728`) still arrives with the same permissions
- [ ] Removal after harness readiness remains effective
- [ ] `/run/omashiki/state`, the single writable point used for rotating OAuth
      state, works through virtio-fs

### NFR-003 — Isolation

This should continue to hold inside the guest, but confirm that the Docker API
propagates `CapDrop`, `no-new-privileges`, `ReadonlyRootfs`, and `PidsLimit`
(`container_manager.ex:1738`) to the microVM.

### Network

- [ ] `ExtraHosts` with `host.docker.internal` — traffic now leaves through a
      virtual NIC. This is the network item most likely to break, because the
      LLM gateway and the tool proxy live on the host
- [ ] Port publishing on 127.0.0.1 for HTTP harnesses
- [ ] `NetworkMode: none` still means total isolation

**`network = "host"` has no microVM equivalent.** A guest with its own kernel
cannot share the host network namespace, so that mode cannot be carried over as
written. The scope of that loss is narrow: all six declarations of
`network = "host"` are load-test tiers — `[environments.loadtest]`
(`omashiki.toml:183`) and the five `lt-*` tiers (`:223`, `:252`, `:281`,
`:314`, `:345`). The environments meant for real work use `none`
(`[environments.opencode]`, `:110`) and `restricted`
(`[environments.codex]`, `:154`), and both have microVM equivalents. Kata
therefore does not block the production environments; it does block re-running
the load-test tiers unchanged, which matters because those tiers are the
comparison baseline.

### `exec`

`op_execute` becomes a kata-agent call over vsock. It works, but it is slower —
check it against the `pre_steps` and `post_steps` timeouts.

## Behavior That Changes

**tmpfs comes out of guest RAM, not host RAM.** Today `/tmp` is a 512 MB tmpfs
(`container_manager.ex:1742`) inside a 512 MB cgroup. A microVM gets fixed RAM
and the tmpfs is carved out of it, so guest memory must be
`>= tmpfs + workload` or the process OOMs inside the VM. Review
`[environments.*.resources].memory` together with `agent_tmp_size_mb`.

**The density arithmetic changes.** Each sandbox gains a guest kernel plus the
kata-agent, on the order of 100-150 MB of overhead against the few MB a
container costs. The concurrent-sandbox ceiling per host drops substantially.
Redo the load-test arithmetic before comparing any number to the Docker
baseline.

## Mandatory Benchmark

**virtio-fs with many small files is the known weak point of Kata, and
`git worktree add` is exactly that pattern.**

Measure against the Docker baseline:

1. `provision_worktree` plus checkout time
2. Total provisioning time to harness readiness
3. Memory overhead per sandbox
4. `op_execute` throughput for `pre_steps`

If (1) degrades badly, the mitigation is to move the worktree out of virtio-fs:
mount it as a block device, or perform the checkout inside the guest from a
remote — which becomes natural after Phase 1 of the
[distributed execution roadmap](distributed-execution.md).

## Alternatives Considered

**gVisor**, if KVM is unavailable. Also a drop-in runtime, bind mounts work
normally, and it needs no nested virtualization. But it gives no hardware
boundary, and its syscall-interception cost is worst under heavy filesystem
load — the worktree again. Plan B only.

**A sandbox platform (CubeSandbox / E2B)** fits behind the same behaviour as a
third backend, for when the goal is density and tens-of-milliseconds cold start
rather than isolation with a minimal diff. These are different goals: Kata does
not deliver 60 ms starts or snapshot forking, and the platform does not deliver
bind mounts for free. If that route is taken, write the adapter against the
**E2B API**, not against Cube — the Cube API is compatible by design, and
targeting the interface avoids coupling to a young project.

A REST backend is also more favourable to the BEAM than Docker is: it trades a
single daemon socket that serializes container create/start for a Finch pool,
and concurrent provisioning becomes processes, which is where the BEAM is
strong. Keep any such backend pure I/O; never shell out to a runtime binary.

## Do Not Do

- **Kata over Firecracker.** No virtio-fs means no bind mounts, which removes
  the reason for choosing Kata at all.
- **MMDS for secret delivery.** It looks like the native microVM primitive, but
  it lives at `169.254.169.254`, the single most probed SSRF target on the
  internet — and this system runs model-generated code. Worse than the current
  bind mount.
- **Kernel cmdline for secret delivery.** Visible in `/proc/cmdline`.
- **Replacing `LlmEgress.Proxy` / `SupplyChain.Proxy`** with whatever the
  runtime offers. Policy is bound to the captured environment digest;
  delegating it moves policy outside the component that captures it and couples
  the guarantee to the runtime.

## References

- [Container boundary](../server/lib/omashiki/runtime/container_manager.ex)
- [Container manager behaviour](../server/lib/omashiki/runtime/container_manager_behaviour.ex)
- [Runtime capability](../server/lib/omashiki/runtime/capability.ex)
- [Runtime value helpers](../server/lib/omashiki/runtimes.ex)
- [Runtime schema](../server/lib/omashiki/runtimes/runtime.ex)
- [Harness profile registry](../server/lib/omashiki/harnesses.ex)
- [Harness types](../server/lib/omashiki/harness/types.ex)
- [Declarative configuration](../omashiki.toml)
- [Requirements](requirements.md)
