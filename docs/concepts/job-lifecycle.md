# The life of a job

A job is one instruction, one context, and the name of one environment.
This page follows one job from the tracker to the result.

## The steps

1. The developer logs in to their house. No machine is involved.
2. The developer sends a job: an instruction, a repository the house knows,
   and the name of an environment. The developer does not send keys, a
   model, a plugin, or "run on machine 3".

   ```bash
   curl -X POST http://house-a.lan:4010/api/v1/jobs \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"schema_version":1,"idempotency_key":"k1","correlation_id":"c1",
          "repo":"app","environment":"review",
          "payload":{"instruction":"review PR 42","title":"review-42"}}'
   ```
3. The house admits the job and captures a snapshot of what it accepted:
   repository, environment, preset, plugin, and their digests. A later
   reload of the house cannot change this job.
4. A free machine polls the houses it serves: "I have a slot, is there
   work?". It does not select a person.
5. The house offers **this** job. The machine checks the worker token of
   that house and accepts the job into a local slot. It does not ask for the
   password of the developer.
6. The machine starts a sandbox for this job only. The agent works inside
   the sandbox. When the job ends, the sandbox is removed.
7. The agent may need a model, a tool, or a package. For each of them it
   talks to the **house of this job**. It uses a token signed for this
   job. The model key stays in the house. If the machine cannot reach that
   house, it refuses the job.
8. The machine verifies the result and returns it to the house that offered
   the job. The other houses answer 404 for this job.
9. The house records the result and sends a signed terminal webhook.

## The three result sinks

The environment declares the sink. The payload never says what kind of
work this is.

| Sink | What the agent gets | What returns to the house | Typical jobs |
| --- | --- | --- | --- |
| `git` | A clean worktree of a registered repository | A committed branch on the remote of **this** job. The machine pushes it after the rules of the house. The agent never pushes | Implement, refactor, fix, migrate |
| `files` | An empty or seeded workspace, no repository | A `tar.gz` of the changed files, checked by digest, stored by the house | Reports, generated documents, datasets, analyses |
| `none` | A workspace and tools | Only the record that the job ran. The work is the actions the agent took through the house | Triage an issue, label it, comment as the agent identity, call an MCP server |

## Failure is also a result

A failed attempt leaves a durable error record. A retry opens the same job
as a new attempt. The webhook fires in both cases.

## Contract and proof

- HTTP contract: [api/jobs-openapi.json](../api/jobs-openapi.json)
- Proof: `mise run e2e:two-houses` runs one job of house A and one job of
  house B on the same machine, kills house A, checks that house B continues,
  and starts house A again without a new enrollment.
