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
OMASHIKI_UID=1000
OMASHIKI_GID=1000
OMASHIKI_DOCKER_GID=967
OMASHIKI_MANAGER_URL=http://manager.lan:4010
OMASHIKI_WORKER_URL=http://worker.lan:4012
```

Use the same `SECRET_KEY_BASE` for the manager and the worker.
Use the same worker token for the manager and enrollment request.
Use the same enrollment secret for the worker listener and enrollment request.
On the worker host, set `OMASHIKI_UID` and `OMASHIKI_GID` to the output of `id -u` and `id -g`.
Set `OMASHIKI_DOCKER_GID` to the output of `stat -c %g /var/run/docker.sock`.
The worker runs as that user and group, in the group of the Docker socket.
The worker uses your home directory, so the host Docker daemon sees the same paths as the worker container.
If Compose runs from another account, set `OMASHIKI_HOST_HOME` to the home path of the account that `OMASHIKI_UID` names.

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

Create the cache and state directories on the worker host, so that they belong to your account:

```bash
mkdir -p ~/.cache/omashiki ~/.local/state/omashiki
```

The worker keeps its mirrors and job directories in `~/.cache/omashiki`.
It keeps its enrollment in `~/.local/state/omashiki/workers/`, in a file named after the Compose project.
The files that it writes there belong to your account.

The worker reads host credential origins inside its container.
If an environment uses host credentials, first [mount their origins](how-to-configure-model-access.md#mount-the-origins-into-a-container) into the worker.

From the worker checkout:

```bash
docker compose --env-file .env -f examples/compose.worker.yml up -d --build
```

With `-f`, Compose reads `.env` from the directory of the Compose file, so name it with `--env-file`.
The worker and its job containers share a Docker network that `compose.worker.yml` creates.
Its name is the Compose project name followed by `-agents`.
The worker reaches each job container on that network.

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
When the manager fails an attempt, the worker removes its container at its next report and logs the removal.
Each container carries the id of its house in the `omashiki.house` label.
The worker removes only containers of the houses it serves, so other houses and workers can use the same Docker daemon.
Run the manager and the worker at the same release. A worker refuses an offer that does not name its house.

To stop the deployment, run the applicable command on each host:

```bash
docker compose --env-file .env -f examples/compose.worker.yml stop
docker compose -f examples/compose.manager.yml stop
```

Keep the manager volumes to retain the queue.
The worker keeps its enrollment in `~/.local/state/omashiki/workers/` across restarts.
Next, [share the worker between houses](how-to-share-workers-between-houses.md).
