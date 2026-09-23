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
It waits up to 15 seconds for PostgreSQL to accept connections before it applies migrations.
It then starts Phoenix in the foreground.
Open <http://127.0.0.1:4010>.

The checked-in configuration disables browser login for local use.
Job submission still requires an API token.
Issue one with `mix omashiki.token create`, as shown in [API authentication](api.md#authentication).
For an authenticated installation, set `[auth].enabled = true` and restart the house.
Use `/signup` to create the first operator account when signup is available.

## 3. Check the service

```bash
curl --fail-with-body http://127.0.0.1:4010/api/v1/health
```

A successful response shows that the service answers.
It does not show that an agent credential works.
[Submit a job](how-to-submit-a-job.md) to check execution.

## 4. Check the installation

```bash
mise run doctor
```

The doctor checks Docker, the agent images, and the network of each `restricted` environment.
It also checks the host credential files and each GitHub App identity.
When the house runs, it starts a short-lived container to check that containers reach `[app].port` on the host.
Each check prints `ok`, `warn`, or `error`. Each problem has a fix.
The task exits with a non-zero status when a check reports an error.

The house runs the same checks in the background when it starts, and logs each warning and error.
The System screen at `/system` shows the latest results.
It repeats the checks every minute. The container check runs only at startup.

## 5. Stop the installation

Press `Ctrl+C` in the foreground terminal.
This stops Phoenix. The database container keeps running.
Stop the database container:

```bash
mise run stop
```

Keep the database volume to retain the queue.
Use `mise run up` to start the installation again.
The `up:fresh` task deletes local state. Do not use it for a normal restart.

## If startup fails

Run `mise run doctor` first. It reports most of these conditions with a fix.

| Condition | Action |
| --- | --- |
| Docker is unavailable | Start Docker. Check your account's daemon access. |
| A port is occupied | Check `[app].port` and `[db].port`. The examples use `4010` and `5442`. |
| A variable is missing | Set the named variable in `.env`. Restart the process. |
| The registry is invalid | Correct the reported field in `omashiki.toml`. |
| A job fails with `harness_unreachable_no_network` | Set `OMASHIKI_AGENT_NETWORK_MODE` for `restricted` environments. See [configuration](configuration.md#environment-settings). |
| An agent runs until its timeout without its tools | Allow the agent network to reach `[app].port` on the host. A host firewall such as `ufw` can block it. |

Next, [register a repository](how-to-register-a-repository.md), or [add a worker](how-to-add-a-worker.md).
