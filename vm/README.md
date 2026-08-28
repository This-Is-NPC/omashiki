# Distributed VM E2E

`vm/run.sh` runs the complete two-node smoke test against the current working
tree. It creates or reuses only the owned `qemu:///system` domains
`omashiki-node-1` and `omashiki-node-2`, while leaving `test1`, `test2`, and
all other domains and volumes alone.

The harness:

- copies the current source and dirty diff into `.temp/vm-e2e-*/source`;
- generates a run-local `omashiki.toml` and never edits the repository config;
- runs core on the host with `OMASHIKI_NODE=core` and scheduler limit `0`;
- provisions Fedora Cloud VMs with Docker, Mix/Elixir, Erlang, Git, SSH, and Python;
- builds the current `agent-jcode` image once, then saves/loads it into both VMs;
- uses SSH reverse tunnels because the development DB config intentionally uses `localhost`;
- creates a temporary SSH-only bare Git remote whose forced key accepts only
  `git-upload-pack` and `git-receive-pack` for that exact remote;
- admits exactly four independent batch jobs and checks DB assignment, overlap,
  labels, fake-provider concurrency, clean worktrees, canonical SHAs, cleanup,
  branches, output, and capacity;
- uses a nonblocking global lock because the guest ports and service paths are
  intentionally fixed, and refuses occupied host or guest ports;
- records every cleanup obligation from post-cleanup verification, including
  process groups, tunnels, database, runtime files, image tags, authorization,
  known-host additions, SELinux state, and labelled containers.
- creates source and log directories under a fresh run-scoped guest root; no
  persistent VM source or log directory is used.

Prerequisites are checked before mutation: Docker, libvirt system access, the
Fedora base at `$HOME/vms/base` (or `OMASHIKI_VM_BASE`), `~/.ssh/id_vms`, and
local PostgreSQL and agent image build inputs. A missing capability is reported
as a blocker rather than weakening an assertion. The guest login remains the
explicit `fedora` user.

Run from the repository root:

```bash
vm/run.sh
```

The command is noninteractive and exits zero only after all assertions pass.
Logs, the generated config, source snapshot, and JSON report remain under the
private, gitignored `.temp/vm-e2e-*` directory. The ephemeral host runtime,
private key, seed, wrapper, remote, guest key, image tag, processes, tunnels,
database container, and temporary Git authorization are removed only after
evidence is copied. Pre-existing SSH file content and modes are preserved;
symlinked SSH files are rejected. Owned VM definitions are preserved and VMs
started by the test are shut down.

SIGINT, SIGTERM, and SIGHUP enter cleanup. SIGKILL cannot be handled, so a
SIGKILL may leave resources behind and requires manual inspection of the latest
report and VM/container state.
