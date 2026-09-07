# Kata runtime

Kata is a Docker runtime handler, selected as `docker.kata.debian`.
The host must install and register the handler before Omashiki can use it.
Configuration support does not establish full workload compatibility.

## Host installer

`.scripts/kata_install.sh` reads pinned version, archive, checksum, and path settings from `vm/manifest.toml`.
It verifies the archive before installation.
It validates the candidate Docker daemon configuration.
It restarts Docker only when the configuration requires a change.
The installer uses administrator privileges.

The repository task is:

```bash
mise run kata:install
```

The host needs hardware virtualization and access to KVM.
VM-based tests additionally need nested virtualization.
Use the checked-in manifest for the exact archive pin.

## Runtime selection

The environment selects `docker.kata.debian`.
The runtime catalog maps its plugin to an image tag.
The Docker request selects handler `kata`.
The same agent image family also supports the runc catalog.

The sandbox receives the normal admitted launch plan.
The runtime handler does not permit the caller to change credentials, mounts, or network policy.

## Host smoke test

```bash
mise run kata:smoke
```

This task builds jcode and starts one disposable labelled container.
It checks runtime selection and Docker exec.
It removes that container after the check.
The smoke test uses host Docker, not a VM.

## Compatibility checks

Before a deployment claim, check the actual workload against these requirements:

| Area | Required check |
| --- | --- |
| Filesystem | Read-only root, temporary storage, worktree visibility, and ownership IDs. |
| Mounts | Declared files, cache directories, and required Unix sockets. |
| Credentials | Private copies, writable OAuth state, and cleanup. |
| Network | Gateway, tool proxy, package access, and egress policy. |
| Process control | Readiness, exec, timeout, cancellation, and cleanup. |
| Resources | CPU, memory, and PID behavior for the selected handler. |
| Results | Git publication or archive delivery through the normal finalization checks. |

A passing smoke test proves only the checks that it executes.
It does not establish all rows above.
Use [distributed tests](how-to-run-distributed-tests.md) for the VM runtime matrix.
Record the exact host and runtime versions with new evidence.
