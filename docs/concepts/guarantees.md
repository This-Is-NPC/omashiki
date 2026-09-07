# Guarantees

This page lists what never happens, what lives where, and the promises the
code backs.

## What never happens

- A developer logs in to a machine, by SSH or by a login on the node.
- A machine has users ("the account of developer A on this worker").
- A machine keeps the password of a developer, their model key, or their
  list of jobs.
- A machine returns the result of house A to house B.
- The agent, inside the sandbox, pushes to the canonical remote.
- The private key of the App, the webhook secret, or the installation token
  goes into the job, the sandbox, or the machine.
- The GitHub webhook reaches the machine.
- The `~/.claude` directory of a developer is mounted on a machine.
- `host_credentials` or identities appear in `worker.toml`.
- An `include` includes another `include`, or a second file wins the same
  name.
- A relative path (`./` or `../`) is the origin of a credential.
- An App of the organization sends issues to house A **and** house B. A
  client belongs to one house.

## The four proofs

| Proof | Who proves | To whom | Meaning |
| --- | --- | --- | --- |
| The machine is in the fleet | The machine | The houses you enrolled | "I can run work" |
| This person is developer A | The developer | Only their house | "I can send and see my jobs" |
| This work is this job | The house | The machine, for this job | "Run this, return only to me, talk to me for the model" |
| This client is the App of house A | The handler | Only house A | "I can send work and receive the end" |

GitHub proves itself to the handler. The handler proves itself to the
house. The house proves the **job** to the machine. Nobody skips a step.

## What lives where

**In the house.** The identity of the developer. The queue. What the
developer can run. The model keys. The history. The published result. The
agent identities, with their keys. The `include` list. The declaration of
`host_credentials` (kind and path form, not the file). The clients at the
door and where to notify them.

**On the machine.** Capacity. Docker. The temporary place of the sandbox.
The Git mirror of **that** job, separated by house. The subscription file
of the machine in the `~/` of this process, if the environment uses a
subscription; then the copy for the attempt, then the removal. The enrolled
houses: id, URL, and token of each.

**Never on the machine.** The password of the developer. The model API
keys. The database of the house. The other jobs of the same person. The
private key of the GitHub App, the webhook secret, the installation token.

**In the handler, in front of the house.** The GitHub webhook secret. The
event mapping. The App as a **client** that sends work.

## The promises

Each line is a promise of the product. In italics: where the code backs
it.

1. You connect N machines once. The developers do not connect machines.
   *The worker starts with no house. Houses arrive by enrollment. `e2e:two-houses`.*
2. Each developer lives in their own house.
   *One database, one registry, and one worker token per house. The worker does not mount the database.*
3. The developer logs in to the house. The house authenticates the **job** on the machine.
   *Worker token per house on poll. Signed claims per job on the data plane.*
4. The machine has no users.
   *The worker knows only id, URL, and token of each house. `worker.toml` has no credentials.*
5. The same machine runs developer A and developer B without knowing the names.
   *One job of each house in parallel on the same worker. Mirrors per house id.*
6. The model key of developer A never lives on the machine.
   *`api_key` stays in the house. The container talks to the gateway of its house.*
7. The result of developer A exists only in house A.
   *`Complete` and blobs go only to the manager that offered. The other house answers 404.*
8. Removing developer A from the fleet does not stop the machines or developer B.
   *`DELETE /internal/enroll/<id>`. Kill and restart of one house proved in the E2E.*
9. The GitHub identity of the agent lives in the house, not on the machine.
   *`[identities.<name>]`, kind `github-app`, key only as `${env:VAR}`.*
10. The job does not carry an App key. `worker.toml` has no GitHub.
    *Admission removes `private_key`. The offer carries name, kind, and public ids.*
11. The machine does not need to know that the issue came from GitHub.
    *The handler sends instruction, context, and the name of the environment. Nothing more.*
12. The client of house A does not send work to house B. The identity of one house does not serve another.
    *API token per house. The broker resolves the identity by the admitted name and refuses if the house changed it.*
13. One file or many files, the product is the same.
    *Same digest for the single file and the split.*
14. `include` only in the root. A repeated name stops the boot.
    *`Config.Error` on collision. Depth one. No path outside the house directory.*
15. The client that POSTs selects the **name** of the environment.
    *The `environment` field of admission.*
16. `~/` in `host_credentials` expands on the machine that runs the container.
    *The `~/` form travels in the snapshot. The copy expands against the `HOME` of the process.*
17. Jira/MCP is not an identity. A GitHub App is.
    *`identities.kind` accepts only `github-app`. Jira stays in `mcp_servers` of the environment.*

## Known limits

- The identity broker was proved against a simulated GitHub, not a real App.
- Only the `opencode` harness receives the MCP configuration that lists the
  identity.
- A developer cannot select "I want GPU-1". The house sends work. The fleet
  places it where there is a slot.
- One house with many developer logins is a different product.
- OAuth refresh writes to the copy of the attempt. There is no write-back to
  the `~/` of anybody.

How we got here, phase by phase:
[internal/house-fleet-implementation.md](../internal/house-fleet-implementation.md).
