# Generic Task Processor

Design direction for serving any product that wants AI integration, not only
code work, without giving up the boundary that makes the system defensible.

The premise does not change: **the caller still controls nothing about
execution.** It sends an instruction and picks an `environment` that the
operator declared. Everything that differs between "review this contract" and
"implement this feature" is an operator declaration.

Status: **not implemented**, except for section 3, which already works today.

## Principle: The Environment Is the Only Selector

The separation already exists and is already correct:

| Layer | Contents |
| --- | --- |
| Envelope (`contract/v1.ex`) | `repo`, `environment`, priority, idempotency — selectors resolved against the registry |
| Payload (`contract/payload_v2.ex`) | `instruction` plus `context` — the work, with no execution control |

`payload_v2.ex` rejects `harness`, `provider`, `auth`, and `model` on purpose
(BR-002).

**Do not add a `type` field to the payload.** It would be the same control under
a different name, and it would create two sources of truth that can disagree:
the client says `"analysis"`, the environment provisions a worktree, and now the
cartesian product has to be validated. Task type is a property **derived** from
the resolved environment, never an assertion by the caller.

## 1. Result as a Sum Type

Today the result is only `(branch, base_sha, head_sha)` plus `worktree_clean`
(`jobs/git_artifact.ex:80-90`). It becomes a declaration on the environment:

- `result = "git"` — today's behavior. A clean committed branch, BR-008 intact
- `result = "data"` — a structured payload, nothing committed
- `result = "both"` — commits and returns a payload

### Production contract

A fixed path in the workspace: the harness writes
`/workspace/.omashiki/result.json`. Finalization reads it, validates it, and
persists it alongside the terminal event.

- Size cap of 256 KB. Above that, a blob with a signed URL — build it only when
  there is real demand
- Under `result = "data"`, nothing is committed
- Under `result = "git"`, the file is ignored

### Structured validation

The environment declares a JSON Schema. Finalization **validates** against it;
a mismatch fails the attempt with a structured error.

That is the point of the feature: it becomes a guarantee rather than a
convention. A webhook consumer can trust the shape without defending itself
against malformed model output.

### Delivery

No change. `GET /api/v1/jobs/:id/result` (FR-004) returns the payload, and the
signed webhook carries the same content. HMAC, the 24-hour retry, and event-ID
deduplication already exist (BR-009, NFR-009).

### Note on NFR-011

Durable data deliberately excludes complete model responses today. A structured
result is **product output**, not observability, so it has to be an explicit and
bounded exception — a schema-validated payload under a cap. Without both, it
becomes an open door for whole transcripts to land in PostgreSQL.

## 2. Optional Repository

Every job requires a registered repository today: admission resolves and
captures the snapshot, and the runner provisions a worktree unconditionally
(`jobs/git_artifact.ex`). Pure analysis has no repository, so the environment
declares that it does not use one:

- **Admission** stops requiring `repo` for those environments
- **Runner** mounts an empty tmpfs working directory in place of the worktree

The constraint that ties it together: no repository means the result can only be
`data`; with a repository, `git`, `data`, or both are available.

In that mode the agent's inputs are `instruction`, `context`, and the
environment's MCP servers — enough for "analyze this and return the verdict".

## 3. Tools Over MCP — Already Implemented

This needs no code. It is configuration:

```toml
[environments.contract-review]
harness = "claude"
capabilities = ["clm__*", "search__query"]

[environments.contract-review.mcp_servers.clm]
url = "https://clm.internal/mcp"
headers = { Authorization = "Bearer ..." }
```

How it works (`tools/proxy.ex`, `tools/mcp_config.ex`,
`config/registry.ex:327`):

- `Tools.Proxy` mints a job-bound token; the container talks **to the proxy**,
  never to the upstream
- The proxy validates the claim, filters `tools/list`, and blocks any
  `tools/call` outside the allowlist. `capabilities` accepts an exact name or a
  `foo__*` prefix
- `headers` stay on the host — an MCP credential never enters the container,
  the same boundary as the LLM key (NFR-007)
- The registry rejects unknown keys and non-absolute URLs at declaration time

## 4. Documents as a Repository, Where It Fits

Not every non-code case has to be `data`. Contract review against a document
repository is a good fit: the contract is versioned, the agent commits
`review.md`, the diff is the artifact, and the history is the audit trail.

Choose per case:

- **Versioned input, auditable output** → document repository, `result = "git"`
- **Ephemeral event, immediate answer** → no repository, `result = "data"`

## Order of Work

1. `result` on the environment, plus reading `/workspace/.omashiki/result.json`
   at finalization, with a cap
2. A JSON Schema per environment, validated at finalization
3. Optional repository: relaxed admission plus an empty workdir in the runner
4. An image per harness profile — a document environment does not need the full
   code toolchain
5. Check the "likely secrets" heuristic for false positives on natural-language
   text

Items 1 and 2 are independent of item 3. Item 3 carries the most code, and even
that is one branch in provisioning plus one relaxed validation.

## Do Not Do

- **A `type` field on the payload.** It violates BR-002 and duplicates the
  selector. The environment already says it.
- **A fully pluggable artifact.** Dissolving BR-008 and the finalization that
  rejects secrets, symlinks, and protected paths removes the defensible part of
  the product.
- **A result with no cap or no schema.** It becomes a transcript drain into
  PostgreSQL and breaks the NFR-011 promise.

## References

- [V1 job envelope](../server/lib/omashiki/jobs/contract/v1.ex)
- [V2 neutral payload](../server/lib/omashiki/jobs/contract/payload_v2.ex)
- [Job lifecycle](../server/lib/omashiki/jobs.ex)
- [Git artifact boundary](../server/lib/omashiki/jobs/git_artifact.ex)
- [Tool proxy](../server/lib/omashiki/tools/proxy.ex)
- [MCP configuration](../server/lib/omashiki/tools/mcp_config.ex)
- [Configuration registry](../server/lib/omashiki/config/registry.ex)
- [Requirements](requirements.md)
