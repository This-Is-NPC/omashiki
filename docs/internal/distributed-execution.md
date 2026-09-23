# Distributed execution

The manager owns admission, policy, and durable job state.
The worker executes offers without database access.
Both roles use the same release.

## Topology

One manager can serve several workers.
One worker can serve several managers.
Each manager is an independent house with its own database and registry.
The worker identifies a house by its enrollment ID and connection settings.

```mermaid
flowchart LR
    A[House A] -->|offers| W[Worker]
    B[House B] -->|offers| W
    W --> Slots[Shared local slots]
    Slots --> SA[Sandbox for A]
    Slots --> SB[Sandbox for B]
    SA -->|model and tools| A
    SB -->|model and tools| B
    W -->|A completion| A
    W -->|B completion| B
```

## Enrollment

The worker listener accepts an enrollment secret.
`POST /internal/enroll` adds or replaces a manager entry.
`GET /internal/enroll` returns IDs and URLs without token values.
`DELETE /internal/enroll/<id>` removes one entry.
The worker persists its enrollment state across restart.

`worker.toml` contains machine limits and Docker settings.
It does not contain the house registry, identity keys, or provider API keys.
Credential path declarations arrive through the admitted environment.
The worker resolves permitted host credential origins on its own machine.

## Work protocol

| Endpoint | Responsibility |
| --- | --- |
| `POST /internal/work/register` | Register worker presence with a manager. |
| `POST /internal/work/poll` | Request available work. |
| `POST /internal/work/report` | Send free slots, capacity, and this house's containers; receive the dead ones. |
| `POST /internal/work/accept` | Accept an offer under worker capacity. |
| `POST /internal/work/reject` | Refuse an unusable offer. |
| `POST /internal/work/heartbeat` | Renew active execution information. With `held: true`, ask what to do with output held for review. |
| `POST /internal/work/complete` | Return a fenced completion: terminal, or output held for review. |
| `PUT /internal/work/blobs/{job_id}` | Upload a file result before completion. |

Worker authentication is separate from operator API authentication.
Offers carry admitted snapshots and the data-plane connection for that house.
Each offer also carries the job's secret-scan policy: the house key for finding fingerprints and the fingerprints allowed for the job's environment and repository.
The worker drops allowed findings from its scan and never logs the key.
The worker checks the offer before it executes the job.
A missing image or invalid snapshot must not produce successful execution.

## Capacity and leases

`Omashiki.Worker.Slots` is the local authority for a worker's capacity.
The limit applies across all enrolled houses.
The poller visits enrolled houses in round-robin order.
Presence is per house and includes available capacity.
The documented stale threshold is thirty seconds without a poll.

## Fleet reports

`Omashiki.Runtime.ContainerTracker` keeps the containers of each executing node.
`ContainerManager` publishes created, started, and removed events after each Docker call.
A census every ten seconds corrects the list.
The worker sends a report after each container change and every five seconds.
A report to a house contains only containers of attempts the worker accepted from that house.
The manager validates the report and records it with the worker presence.
The report does not change a job, a lease, or capacity.

The manager answers a report with the reported containers whose attempt is not provisioning or running.
The worker removes each of those containers that is at least thirty seconds old and logs the removal.
A younger container waits for a later report, so an attempt that is still starting keeps its container.
The worker never removes a container it did not report to that manager.
This reclaims the container of an attempt the manager failed while the worker kept running.

Each offer carries the house id of the manager that sent it.
The worker refuses an offer without one, or with one that is not a UUID.
Before it runs the attempt, the worker stores that house id with the manager ID in its enrollment state file.
It labels the attempt's container with the house id in `omashiki.house`, as the house labels its own containers.
The census and the cleanup at start of a worker cover only containers of the house ids of its enrolled managers.
The cleanup also removes the credential copies of those house ids, and only those.
Manager IDs are local names and do not decide ownership.
Other houses and other workers can share the Docker host, and a worker never lists or removes containers of a house it does not serve.
Removing an enrollment also forgets that manager's house id.

Manager leases and worker slot ownership prevent duplicate acceptance and completion.
A stale completion cannot replace the result of a later attempt.
A failed manager connection does not remove another house's work.

## Results

| Sink | Worker action | Manager action |
| --- | --- | --- |
| `git` | Validate and publish to the captured remote. | Record branch and revision metadata. |
| `files` | Create and upload the validated archive. | Verify its digest and store the result. |
| `none` | Return completion metadata. | Record the terminal result. |

Output held for review stays on the worker that produced it.
The worker completes the attempt with a `review` complete, and keeps a record of the output.
The answer to a heartbeat with `held: true` says `publish` after an approval and `cancel` after a rejection or a cancellation.
The worker then publishes to the manager that offered the attempt, or removes the output.

A files completion cannot refer only to a worker-local path.
The manager must have the blob before it accepts success.
Mirrors, job state, and completion destinations remain separated by manager ID.
The worker must not infer a different remote or destination from live local configuration.

## Data plane access

The worker and its containers must reach the offering manager.
A job uses that house for model gateway, tool proxy, and identity broker access.
The container receives temporary claims rather than the house's provider keys.
A loopback manager URL is unsuitable for remote or separate-container access.

## Verification

`e2e:host-worker` checks separate host processes.
`e2e:compose-worker` checks release images and HTTP enrollment.
`e2e:two-houses` checks shared slots, separate results, and independent manager recovery.
VM tests check the distributed runtime in disposable machines.
See [the distributed test procedure](how-to-run-distributed-tests.md).
