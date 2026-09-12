# Omashiki

 ### *Jobs, containers... and ~~chaos~~ worktrees.*

Omashiki runs agent jobs through a durable queue and controlled containers.
A client supplies an instruction and selects a registered environment.
The house stores the job, credentials, and result.
A machine executes the job with the tools and access declared by the operator.

Use one process on a laptop, or give several houses access to shared workers.
Supported plugins are OpenCode, Claude Code, OpenAI Codex, pi, and jcode.

## What a job can produce

The environment selects the result sink.
The client cannot override its runtime, credentials, mounts, or network policy.

| Sink | Result | Example work |
| --- | --- | --- |
| `git` | A verified committed branch. | Fix a bug, update a dependency, or write a versioned document. |
| `files` | A validated file archive with a digest. | Generate a report, convert documents, or prepare a dataset. |
| `none` | Completion metadata. | Read an issue, add a label, or comment through a declared tool. |

```mermaid
flowchart LR
  caller[Caller<br/>instruction + context<br/>environment name] --> admit[House admits<br/>captures the environment snapshot]
  admit --> run[Machine runs the agent<br/>in the declared sandbox]
  run --> git[git: committed branch]
  run --> files[files: bundle of files]
  run --> none[none: completion metadata]
  git --> hook[Configured terminal webhook]
  files --> hook
  none --> hook
```

A `none` result does not contain a complete record of external changes.
Check the external system when you need to verify an action.

## Where work comes from

A handler can convert a tracker event, scheduled task, or form submission into `POST /api/v1/jobs`.
The request selects registered names and supplies an instruction with optional context.
When the token has a webhook destination, the house sends a signed terminal notification.

![A tracker event enters through a handler. The house admits the job. A worker executes it and returns the result.](docs/assets/job-journey.gif)

Gray identifies the external integration. Green identifies Omashiki.
The [reference GitHub handler](examples/handler/github_issue_handler.py) verifies events and submits labelled issues.
Its terminal callback logs results. Your integration must implement ticket comments or pull-request creation.

## Use cases

**Fix a labelled GitHub issue.** A handler sends the issue description and repository to the house.
The agent reproduces the failure, adds a test, and returns a branch for review.

**Implement a ready Jira ticket.** A handler converts the workflow transition into a job.
Acceptance criteria enter through `context`. The ticket key identifies the correlation.
The handler attaches the result to the ticket.
You supply the Jira connector and callback code.

**Update several repositories.** A scheduled script submits one job per repository and maintenance operation.
Each job has a separate idempotency key and result.
The operator reviews the branches before merging them.

**Prepare a report.** A files environment supplies the required tools and permitted inputs.
The agent writes output files. The house stores the validated archive.

**Delegate from an existing coding agent.** Install the skill from the running house:

```bash
mkdir -p "${HOME:?}/.agents/skills/omashiki"
curl --fail-with-body -sS "$OMASHIKI_URL/api/v1/agent-skill" \
  > "${HOME:?}/.agents/skills/omashiki/SKILL.md"
```

Ask the agent to discover registered environments, submit a bounded task, and retrieve the result.
The job continues after the client disconnects.

## Deployment shapes

The release supports three roles: `embedded`, `manager`, and `worker`.
Select the deployment that matches your database and execution requirements.

### 1. One machine

An embedded process runs the house and local job execution.
PostgreSQL stores the queue.
Use this deployment on a laptop or single server.

```mermaid
flowchart LR
  client[Client<br/>API · handler] -->|POST /api/v1/jobs| house
  subgraph box[one machine · OMASHIKI_ROLE=embedded]
    house[House<br/>registry · queue · gateway]
    pg[(PostgreSQL)]
    house --- pg
    house -->|claim| sandbox[Sandbox container]
  end
  sandbox -.->|model · tools · packages| house
  house -->|result · configured webhook| client
```

Use [the single-node configuration](examples/single-node.omashiki.toml) and [installation procedure](docs/how-to-install-and-stop.md).

### 2. One house, several nodes, one queue

Several embedded nodes share PostgreSQL.
Each node has a declared identity and execution capacity.
Canonical Git remotes make results accessible outside the execution node.

```mermaid
flowchart LR
  client[Client] --> a
  subgraph fleet[declared nodes · shared queue]
    a[Node A<br/>embedded]
    b[Node B<br/>embedded]
    c[Node C<br/>embedded]
    pg[(PostgreSQL<br/>one queue)]
    a --- pg
    b --- pg
    c --- pg
  end
  remote[(Canonical Git remote)]
  a -->|push| remote
  b -->|push| remote
  c -->|push| remote
```

Use [the multi-node configuration](examples/multi-node.omashiki.toml).
This deployment gives each embedded node database access.

### 3. One house with several workers

The manager owns PostgreSQL and the registry.
Workers control Docker and local slots without database access.
Each worker enrolls into the house over HTTP.

```mermaid
flowchart LR
  client[Client] -->|jobs · results| house
  subgraph control[control plane · OMASHIKI_ROLE=manager]
    house[House]
    pg[(PostgreSQL)]
    house --- pg
  end
  subgraph machines[fleet · OMASHIKI_ROLE=worker]
    w1[Machine 1<br/>slots · Docker]
    w2[Machine 2<br/>slots · Docker]
    w1 --> s1[sandbox]
    w2 --> s2[sandbox]
  end
  w1 -->|poll · accept · heartbeat · complete| house
  w2 -->|poll · accept · heartbeat · complete| house
  s1 -.->|job-bound token:<br/>model · tools · packages| house
  s2 -.-> house
  laptop[Operator laptop] -->|mise run worker:enroll| w1
  laptop -->|mise run worker:enroll| w2
```

Follow [worker setup](docs/how-to-add-a-worker.md).
The worker and its job containers must reach the manager's data-plane endpoints.

### 4. Several houses with shared workers

Each house keeps its own queue, registry, credentials, and results.
A worker can enroll into each house with a distinct manager ID.
The worker shares one local slot limit across those houses.

```mermaid
flowchart LR
  devA[Developer A] --> hA
  devB[Developer B] --> hB
  subgraph houses[one house per developer]
    hA[House A<br/>registry · queue · keys]
    hB[House B<br/>registry · queue · keys]
    pA[(PostgreSQL)]
    pB[(PostgreSQL)]
    hA --- pA
    hB --- pB
  end
  subgraph fleet[shared worker fleet]
    w1[Machine 1]
    w2[Machine 2]
  end
  w1 -->|enrolled as house-a| hA
  w1 -->|enrolled as house-b| hB
  w2 -->|enrolled as house-a| hA
  w2 -->|enrolled as house-b| hB
  hA -. "A's results only here" .-> devA
  hB -. "B's results only here" .-> devB
```

Follow [shared-worker setup](docs/how-to-share-workers-between-houses.md).
A failed house connection does not remove other enrollments.

### 5. An agent identity and an integration handler

The handler submits tracker work as a client of the house.
The agent identity lets the running agent act as a GitHub App through the house broker.
These roles use separate credentials and configuration.

```mermaid
flowchart LR
  gh[GitHub] -->|issue labelled · webhook| handler[Your handler<br/>integration client]
  handler -->|POST /api/v1/jobs<br/>environment name · instruction · context| house
  subgraph housebox[House]
    house[Registry · queue]
    broker[Identity broker<br/>acts as the App]
    house --- broker
  end
  house -->|offer| machine[Machine]
  machine --> sandbox[Sandbox]
  sandbox -->|MCP tools/call github_comment<br/>job-bound token| broker
  broker -->|App JWT → installation token| gh
  house -->|signed terminal webhook| handler
  handler -->|custom result callback| gh
```

The house retains the App private key and installation token.
Only OpenCode currently receives the identity MCP configuration.
Follow [identity setup](docs/how-to-configure-an-agent-identity.md) and [tracker integration](docs/how-to-connect-an-issue-tracker.md).

## Start here

You need Linux, Docker with Compose support, and mise.
From the checkout root:

```bash
mise install
mise run up
```

The task starts the local house at <http://127.0.0.1:4010> with the checked-in configuration.
Configure repository and model access before submitting a real job.

[The documentation index](docs/README.md) follows the operating sequence:
install, register a repository, configure an agent, submit work, and retrieve its result.
Read [security and limits](docs/security-and-limits.md) and [known limitations](docs/what-does-not-work.md) for deployment constraints.

## Development

[The internal documentation](docs/internal/README.md) contains development setup, tests, architecture, requirements, and implementation records.
Start with [contributing](docs/internal/contributing.md).

## License

Omashiki uses the [MIT License](LICENSE).
