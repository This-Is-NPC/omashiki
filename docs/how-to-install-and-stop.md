# How to install and stop Omashiki

Use this procedure to run a local house from a checkout.
The house stores jobs. The embedded worker runs the agent containers.

## Before you start

You need a Linux host, Docker with Compose support, and [mise](https://mise.jdx.dev/).
Your account must have access to the Docker daemon.
Run the commands from the repository root.

This procedure starts a checkout. It does not install a system service.
For source development, use [development setup](internal/how-to-set-up-development.md).

## 1. Prepare the configuration

Install the pinned tools:

```bash
mise install
```

The checkout contains `omashiki.toml`. Keep that file if you have already configured the installation.
For a new configuration, copy the single-node example:

```bash
cp examples/single-node.omashiki.toml omashiki.toml
```

If `.env` does not exist, create it from the template:

```bash
cp .env.example .env
```

[Configure model access](how-to-configure-model-access.md) before you submit real work.
Keep secret values in `.env`. The root TOML file is tracked by Git.

## 2. Start the house

```bash
mise run up
```

The task starts PostgreSQL, applies migrations, prepares assets, and builds missing agent images.
It then starts Phoenix in the foreground.
Open <http://127.0.0.1:4010>.

The checked-in configuration disables browser login for local use.
Job submission still requires an API token.
For an authenticated installation, set `[auth].enabled = true` and restart the house.
Use `/signup` to create the first operator account when signup is available.

## 3. Check the service

```bash
curl --fail-with-body http://127.0.0.1:4010/api/v1/health
```

A successful response shows that the service answers.
It does not show that an agent credential works.
[Submit a job](how-to-submit-a-job.md) to check execution.

## 4. Stop the installation

Press `Ctrl+C` in the foreground terminal.
Stop the database container:

```bash
mise run stop
```

Keep the database volume to retain the queue.
Use `mise run up` to start the installation again.
The `up:fresh` task deletes local state. Do not use it for a normal restart.

## If startup fails

| Condition | Action |
| --- | --- |
| Docker is unavailable | Start Docker. Check your account's daemon access. |
| A port is occupied | Check `[app].port` and `[db].port`. The examples use `4010` and `5442`. |
| A variable is missing | Set the named variable in `.env`. Restart the process. |
| The registry is invalid | Correct the reported field in `omashiki.toml`. |

Next, [register a repository](how-to-register-a-repository.md), or [add a worker](how-to-add-a-worker.md).
