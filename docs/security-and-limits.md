# Security and limits

The house controls execution policy.
A client selects registered names and supplies an instruction with optional context.

## Access boundaries

| Location | Stored data |
| --- | --- |
| House | Operator account, queue, registry, provider API keys, identity keys, and results. |
| Worker | Local slots, Docker access, enrollment tokens, mirrors, and temporary attempt state. |
| Sandbox | Job workspace, declared tools, temporary claims, and private credential copies when configured. |
| Integration handler | Tracker authentication, event mapping, and its own callback credentials. |

Provider API keys for gateway access remain in the house.
Subscription credential files are a separate access method.
Those files exist on the execution machine and are copied for each attempt.
Each copy is a private directory in `/dev/shm` named after the attempt and the id of its house.
The copy is removed with the attempt's container.
A cleanup removes only copies of the houses it serves, so other houses on the machine keep the copies of their running attempts.
The worker does not receive the developer's house password or house database.

The GitHub identity broker keeps App keys and installation tokens in the house.
A sandbox receives only the job authorization needed to call the broker.

## Container policy

The runtime drops Linux capabilities and disables privilege escalation.
It uses a read-only root filesystem, bounded temporary storage, and resource limits.
Declared mounts and network settings remain part of the environment policy.
A host-network environment has different isolation properties from a restricted environment.
Omashiki never pulls an image. It runs only images already on the machine, and a missing image is an error that names it.

In an [image install](how-to-install-from-the-image.md), agent containers share a Docker network with the house only. The database is not on it.

The sandbox does not receive the host Docker socket.
The worker controls Docker and is therefore a trusted execution component.
Do not treat worker enrollment as permission to run an untrusted worker operator.

## Approvals

An agent never waits for an approval.
Nobody can answer one inside a container.
Each harness runs in a mode that does not ask.
OpenCode may work inside the job directory and is denied paths outside it.
If an OpenCode session or one of its subagents still asks for a permission, the attempt fails with `agent_waiting_for_permission`.

## Output checks

Before any sink publishes a result, the house checks the files the job wrote or changed.
It refuses the output when:

- a changed path is a symbolic link;
- the changes add up to more than 100 MiB;
- a file is under `.git/`, `.ssh/`, or `.aws/`, whatever it contains;
- [gitleaks](https://github.com/gitleaks/gitleaks), with its default rules, finds a secret such as an API token or a private key in a changed file;
- gitleaks is missing or fails, so the files could not be scanned.

The secret scan judges content, not file names.
It reads only the changed files, never Git history.
It ignores `.gitleaks.toml`, `.gitleaksignore`, and `gitleaks:allow` comments in the output.
The doctor checks that gitleaks runs.

A refused output fails the job with a code that names the check, such as `secret_found` or `protected_path`, and a message that says which file tripped it.
For a secret, the message and the details give the file, the line, and the gitleaks rule, never the secret itself.
See [job errors](api.md#job-errors).

### Output held for review

gitleaks also flags test fixtures, examples, and placeholders.
When the secret scan is the only check that refuses the output, the environment's `secret_scan` setting decides what happens:

| `secret_scan` | Effect |
| --- | --- |
| `review` (default) | The job waits in status `review`. The node that produced the output keeps it: the work directory of a `files` or `none` job, or the worktree and run branch of a `git` job. The container is removed and its slot is free. |
| `block` | The job fails with `secret_found` and the output is removed. |

A symbolic link, an oversized output, a protected path, or an unavailable scanner fails the job in both modes.

The task details on the Home screen and `GET /api/v1/jobs/{id}` show the findings of a job in review: file, line, gitleaks rule, and the match with the secret replaced by `REDACTED`.
An operator decides in the task details, and a client decides with a token that has the `review` scope:

- **Approve** publishes the output with the same step as any output, without the secret scan. The job becomes `succeeded` when the node has published it.
- **Reject** fails the job with `secret_found`. The node removes the output.
- **Cancel** cancels the job. The node removes the output.

Jobs that depend on a job in review keep waiting.

Held output waits for the environment's `review_timeout_ms`, 7 days by default.
The house fixes the deadline when the job enters review, and the task details show it.
When it passes before the output is published, approved or not, the house fails the job with `review_expired`, with the same event and webhook as a rejection, and the node removes the output.
The System screen counts the jobs in review.

### Allowed findings

In the review of a held job, **Allow in this environment** tells the secret scan to stop refusing one finding, with an optional note.
The allowance applies to later jobs of the same environment and, for a `git` sink, of the same repository.
It matches the same secret, in the same file, under the same gitleaks rule; the same secret in another file is refused.
Approve the held job as usual after you allow its findings.
When every finding of an output is allowed, the output publishes without review.
The Config screen lists the allowances, with who created them and when, and removes them.

A finding's fingerprint is an HMAC-SHA256 of the file, the rule, and the SHA-256 of the secret.
Its key is derived from `SECRET_KEY_BASE` on the house and travels to the node with each job, so a fingerprint cannot be checked against guesses of a weak secret without that key.
The raw secret never leaves gitleaks, and the key is never logged.

The node keeps a record of each held output in `~/.cache/omashiki/held`, readable only by the house user.
Recovery, container reclaim, boot cleanup, and a restart of the node leave the output and its record in place.
Every few seconds the node asks the house what to do with each held output, over the attempt heartbeat that carries cancellation.
An embedded house asks itself.
A worker asks the manager that offered the attempt, and publishes to that manager.

A decision is recorded in the house at once.
Only the node that holds the output can publish it, so an approval waits for that node.
While a worker is offline, its held output stays in `review`, and the task details say which node holds it.

The node removes held output without waiting for the deadline when the house says the job was rejected, cancelled, or expired, or that it does not know the attempt, and when the manager refuses the worker's token with `401` or `403`.
The record keeps its own copy of the deadline.
An hour after that deadline the node removes the output in any case, even while the manager is unreachable or no longer configured on the worker.
Before then, an unreachable manager only delays the next question.
Each removal is logged with its reason.
A rejection or a cancellation ends the job at once; the worker removes the output when it is back.
If the node never comes back, reject or cancel the job.

Git finalization also checks worktree state.
A successful Git result identifies a committed branch with base and head revisions.
The machine publishes to the configured remote after validation.
The agent does not receive the canonical remote's push credentials.

File results use path validation and a digest-checked archive.
A `none` result contains completion metadata.
Cancellation cannot reverse an external action that already completed.

## Terminal webhooks

A terminal webhook refuses loopback and private addresses, so a token holder cannot make the house send requests into its own network.
`[webhooks] allow_private_destinations = true` removes that protection for every token. Enable it only when you trust every token holder with that network.

## Limits

| Item | Limit or policy |
| --- | --- |
| Encoded job payload | 1 MiB. |
| Atomic batch | 100 jobs. |
| Priority | Integer from `0` through `3`. |
| Concurrent containers | The execution machine's configured capacity. |
| CPU, memory, PIDs | The environment and machine resource settings. |
| Attempt duration | The environment's `timeout_ms`. |
| Job output | 100 MiB maximum change size. |
| Terminal webhook retries | 24-hour retry window. |
| Event and queue retention | Configured retention; the documented default is 30 days. |
| Git run branches | Default 30-day pruning horizon. Current successful task pointers have separate preservation rules. |

A shared worker has one local capacity limit across its houses.
Increasing that limit does not increase physical CPU, memory, or database capacity.

## Secret rotation

The house derives these values from `SECRET_KEY_BASE`. Changing it invalidates all of them:

| Value | After the change |
| --- | --- |
| Browser sessions | Every operator signs in again. |
| API tokens | Every token stops working. Issue new tokens. |
| Terminal webhook secrets | Webhooks of jobs submitted before the change are not delivered, and failed deliveries cannot be redelivered. New tokens need their webhook secret again. |
| Runtime claims | Running agents lose the gateway, the tools proxy, and the package proxy until their attempt ends. |
| Secret allowances | Finding fingerprints change, so no allowance matches any more and the findings are refused again. Remove the old allowances on the Config screen and allow the findings again from the next review. |

A worker signs runtime claims that its manager verifies, so it uses the same `SECRET_KEY_BASE` as the manager.
Every role refuses to start when `SECRET_KEY_BASE` has fewer than 64 characters. Generate it with `openssl rand -base64 48`.
Keep `SECRET_KEY_BASE` when you back up persistent state.

See [known limitations](what-does-not-work.md) before you rely on an unverified integration or runtime property.
Implementation details belong in [the internal architecture](internal/architecture.md).
