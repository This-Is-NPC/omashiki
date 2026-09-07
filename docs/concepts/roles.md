# Roles

Omashiki has five roles. Keep them apart. If you mix two of them, the design
breaks.

## The operator

You buy and connect the machines. You decide which machines exist and which
houses can send work to them. Developers do not connect machines and do not
get the keys of a machine.

## The developer

A person who wants to send work: "do this, in this repository, in this
environment". The developer logs in to their own house, never to a machine.
The developer sees only their own jobs.

## The house

The house is the Omashiki of one developer. It is also called the **core**
(`OMASHIKI_ROLE=manager`). It holds:

- the login
- the queue
- the declared repositories, environments, and identities
- the model keys
- the history and the results

Two houses never share a queue or a database.

## The machine

A machine is a server with capacity: how many jobs it can run at the same
time. It is also called the **worker** (`OMASHIKI_ROLE=worker`). A machine:

- is not an account and has no users
- does not select a developer
- takes the next job from any house that you enrolled it into
- returns the result only to that house
- becomes free again when the job ends

## The job

The job is the only thing a machine runs. It is a request that a house has
already accepted: what to do, where, until when, and where the result goes.
The house gives the machine the credentials for **this** job. The developer
never talks to the machine.

## The client at the door

A system in front of the house, for example GitHub, Jira, or your own
handler. It listens to the world and turns an event into a job. It logs in
to the house like any other client. It does not enter a machine.

A GitHub App can have two roles. They do not mix:

| Role | What it is |
| --- | --- |
| Client at the door | Your handler receives the webhook and sends a job |
| Agent identity | Declared in the house; the face the agent uses to comment, label, or open a pull request |

See [The client at the door](client-at-the-door.md) and
[Agent identities](identities.md).

## One process or many

The same release runs in three roles:

| Role | What runs |
| --- | --- |
| `embedded` | House and machine in one process. This is what `mise run up` starts |
| `manager` | A house only |
| `worker` | A machine only |

See [Machines and enrollment](machines-and-enrollment.md) for the shapes
you can build from these roles.
