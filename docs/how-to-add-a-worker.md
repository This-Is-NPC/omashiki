# How to add a worker

Use a worker to execute jobs outside the manager process.
The manager stores the queue and registry. The worker controls Docker and local execution slots.

## Before you start

You need compatible checkouts on the manager and worker hosts.
Both hosts need Docker with Compose support.
The worker and its job containers must reach the manager URL.
The enrollment client must reach the worker listener.

The manager configuration needs canonical Git remotes.
Do not use the checkout's `path = "."` repository declaration inside the manager container.
Configure [model access](how-to-configure-model-access.md) on the appropriate host.
Prepare each required agent image on the worker.

## 1. Configure the deployment

Set the required values in `.env` on the relevant hosts:

```dotenv
SECRET_KEY_BASE=replace-with-a-long-random-secret
OMASHIKI_WORKER_TOKEN=replace-with-a-random-worker-token
OMASHIKI_ENROLL_SECRET=replace-with-a-different-random-secret
OMASHIKI_HOST_HOME=/home/worker-user
OMASHIKI_MANAGER_URL=http://manager.lan:4010
OMASHIKI_WORKER_URL=http://worker.lan:4012
```

Use the same worker token for the manager and enrollment request.
Use the same enrollment secret for the worker listener and enrollment request.
Set `OMASHIKI_HOST_HOME` to the execution account's actual home path.
The host Docker daemon must see the same paths as the worker container.

For Compose on one host, use these URLs:

```dotenv
OMASHIKI_MANAGER_URL=http://host.docker.internal:4010
OMASHIKI_WORKER_URL=http://127.0.0.1:4012
```

The worker resolves the manager URL.
The enrollment command resolves the worker URL.
Loopback inside a container refers to that container.

## 2. Start the manager

From the manager checkout:

```bash
docker compose -f examples/compose.manager.yml up -d --build
```

## 3. Start the worker

From the worker checkout:

```bash
docker compose -f examples/compose.worker.yml up -d --build
```

The worker reads [worker.toml](../examples/worker.toml).
This file contains machine limits and Docker settings.
It does not contain the house registry or provider credentials.

## 4. Enroll the worker

From a checkout with the enrollment values in `.env`:

```bash
mise run worker:enroll
```

The task loads `.env` and sends the manager connection to the worker.
Enrollment survives a worker restart.
Use an explicit `--manager-id` when several houses have similar URLs.

## 5. Check execution

[Submit a job](how-to-submit-a-job.md) to the manager.
[Follow the job](how-to-follow-and-retrieve-a-job.md) until it reaches a terminal status.
If work waits, check worker logs, enrollment, available slots, and manager access.
If provisioning fails, check the image catalog and credential paths on the worker.

To stop the deployment, run the applicable command on each host:

```bash
docker compose -f examples/compose.worker.yml stop
docker compose -f examples/compose.manager.yml stop
```

Keep the volumes to retain the queue and enrollment state.
Next, [share the worker between houses](how-to-share-workers-between-houses.md).
