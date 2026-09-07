# Example configurations

Two starting points for `omashiki.toml`. Copy one to the repository root and
edit it; the application always reads `omashiki.toml` at the root, so these are
templates to copy, not files it will find on its own.

| File | Shape |
| --- | --- |
| [single-node.omashiki.toml](single-node.omashiki.toml) | One machine runs PostgreSQL, the API, the UI, and every container. What `mise run up` expects. |
| [multi-node.omashiki.toml](multi-node.omashiki.toml) | Several machines share one PostgreSQL queue: declared `[nodes.*]`, a canonical Git remote, per-machine capacity. |
| [loadtest.omashiki.toml](loadtest.omashiki.toml) | Appendable fragment: the load-test presets, credentials, and environments driven by `.scripts/loadtest/drive.py`. |
| [compose.manager.yml](compose.manager.yml) | Docker Compose for the manager control plane (PostgreSQL + `OMASHIKI_ROLE=manager`). |
| [compose.worker.yml](compose.worker.yml) | Docker Compose for a remote worker (`OMASHIKI_ROLE=worker`, enroll listener on 4012). |
| [worker.toml](worker.toml) | Machine file for workers: host limits and Docker socket path. Manager URL and token arrive via enrollment. |
| [handler/github_issue_handler.py](handler/github_issue_handler.py) | A client at the door: verifies a GitHub webhook, turns a labelled issue into one `POST /api/v1/jobs` envelope, verifies the signed terminal webhook. Stdlib only, with tests. |

```bash
cp examples/single-node.omashiki.toml omashiki.toml
cp .env.example .env
mise run up
```

## Manager and worker Compose

The walking-skeleton split uses the same release image twice:

```bash
cp examples/single-node.omashiki.toml omashiki.toml
cp .env.example .env   # set OMASHIKI_WORKER_TOKEN and OMASHIKI_ENROLL_SECRET

docker compose -f examples/compose.manager.yml up -d --build
docker compose -f examples/compose.worker.yml up -d --build

# laptop → worker enroll listener
mise run worker:enroll
```

`compose.manager.yml` mounts `omashiki.toml` from the repository root.
`compose.worker.yml` mounts [worker.toml](worker.toml), the host Docker
socket, and `${OMASHIKI_HOST_HOME}/.cache/omashiki` at the same absolute path
so Git mirrors match the host daemon. Set `OMASHIKI_HOST_HOME` in `.env` to
this machine's home directory before starting the worker stack. Enrollment is a
one-shot HTTP POST from the laptop; see
[distributed execution](../docs/distributed-execution.md).

When the worker runs on another machine, `--manager-url` (and
`OMASHIKI_MANAGER_URL` in `.env`) cannot be `127.0.0.1` or `localhost` on the
laptop — the worker host and the job containers it starts must be able to reach
the manager over the network (LAN, Tailscale, `host.docker.internal`, or a public
address). Pass `--allow-localhost` to `enroll_worker.py` only for same-host
tests that deliberately use loopback.

`mise run e2e:compose-worker` exercises the packaged Compose path end-to-end.

### Many houses, the same machines

Run `compose.manager.yml` once per house under its own Compose project name,
port, registry and worker token, then enroll the same worker into each house
with a distinct `--manager-id` (the header of that file shows the exact
commands). The worker keeps mirrors, state and results apart per house id and
completes each job only to its own house. `mise run e2e:two-houses` proves it
on one host, including killing and restarting one house.

## Agent identities and the handler at the door

`[identities.<name>]` in the house registry gives the agent a face (first kind:
`github-app`, key as `${env:VAR}` only); a preset wears it with
`identities = ["ana-bot"]`, and while a job runs the sandbox reaches that
identity as an MCP server named `ana-bot` on the tools data plane. The house
acts as the App; the sandbox and the worker never see the key.

The handler in [handler/](handler/github_issue_handler.py) is the other side:
GitHub events become job envelopes carrying only an environment name,
instruction and context, and the signed terminal webhook comes back to it.

## Secrets

Nothing sensitive belongs in `omashiki.toml`: it is tracked by git. Secrets are
written as `${env:VAR}` and resolved from the process environment when the
config loads. `mise` loads the gitignored `.env` into that environment for every
task, so `cp .env.example .env` is the whole setup.

Three fields accept the reference form — `[credentials.*].api_key`,
`[credentials.*].base_url`, and `[repositories.*].ssh_key_passphrase`. The
passphrase *only* accepts it; plaintext is rejected at load. `base_url` takes it
so a private LAN address stays out of the tracked file too.

A `${env:VAR}` whose variable is unset or empty **aborts the boot** naming the
variable. That is deliberate — a missing key fails at startup rather than
becoming a 401 in the middle of an attempt — but it also means every entrypoint
that reads the file is affected, `mise run dev` and the E2E targets included.
Export the variable before uncommenting the block that needs it.

`[repositories.*].path` is validated at load and is deliberately confined: it
must resolve inside the configuration root or into `~/.cache/omashiki/mirrors`,
must not traverse a symlink, and must already be a real Git repository. To
register a repository that lives anywhere else, give it a `remote` and omit
`path` — Omashiki clones into the mirror root and bind-mounts that copy.

## What differs between the two

Everything in the multi-node file is identical on every machine **except**
`[limits]`, which is that machine's own container budget. Three things change
relative to single node:

- **`[nodes.*]`** — a name is the whole declaration. A process picks its own
  node from `OMASHIKI_NODE`, falling back to the hostname. Booting on a machine
  declared nowhere fails config load instead of claiming work under an unknown
  node id.
- **`[repositories.*].remote`** — mandatory once a second machine exists.
  Finalization pushes there, so the result is reachable from a machine that did
  not run the attempt, and collision detection becomes `--force-with-lease`
  against the one repository every node shares.
- **`OMASHIKI_DB_HOST`** — only one machine has PostgreSQL on its localhost.

Implemented today: the canonical remote, node identity, and per-node capacity
rows — still one process shape, every node mounting the same PostgreSQL.
The target is a manager that owns the database and workers that pull snapshots
without `Repo`. See [manager and worker plan](../docs/distributed-execution.md).

## `mcp.json.example`

Omashiki exposes **no MCP endpoint**: there is no `/api/v1/mcp` route in
`server/lib/omashiki_web/router.ex`. The MCP code in the tree runs the other
way round — `Omashiki.Tools.Proxy` is a job-scoped proxy that forwards the
*agent's* MCP calls out to the servers an environment declares under
`[environments.*.mcp_servers.*]`, keeping their credentials on the host. That
config is generated per attempt and merged into the harness's own JSON under
`/run/omashiki/state`; it has nothing to do with a file at the repository root.

The supported way to drive Omashiki from a coding agent is the bundled Agent
Skill, which operates the public HTTP API:

```bash
mise run skill:install
```

[mcp.json.example](mcp.json.example) is kept only as a record of the shape a
project-scoped config would take if a server is ever added. It is deliberately
**not** named `.mcp.json` and **not** at the repository root: agents
auto-discover that exact filename and path, so a copy there is loaded on every
session and fails to connect. `.mcp.json` is in `.gitignore` for the same
reason — if you create one locally it stays yours and out of the repo.

## Why `omashiki.e2e.toml` is gitignored

It is a build artifact, not a hand-written example.
`.scripts/overture_e2e.py prepare` generates it on every E2E run as the tracked
`omashiki.toml` plus provider-specific additions, and stages machine-local
credential snapshots under `.omashiki/e2e/` that it points at. The runner takes
a nonblocking lock precisely because preparation rewrites the file. Committing
it would commit derived, host-specific output that the next `mise run
e2e:overture` overwrites.

The parts of it worth keeping as examples — the gateway-credential block, the
jcode environment, the runtime catalog — are in the two files above instead,
with their secrets as `${env:VAR}`.
