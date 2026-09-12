# How to set up development

Use this procedure for source changes and local tests.
For installation operation, use [install and stop](../how-to-install-and-stop.md).

## Before you start

You need Git, Docker with Compose support, and mise.
Your account must have access to Docker.
Run repository tasks from the checkout root.

## 1. Install tools

```bash
mise install
```

The root `mise.toml` pins the project tools.
Use those versions when you compare local test results.

## 2. Prepare configuration

Keep an existing `omashiki.toml` if it contains required local settings.
For a new setup, copy the single-node example.
If `.env` does not exist, copy `.env.example` to `.env`.

```bash
cp examples/single-node.omashiki.toml omashiki.toml
cp .env.example .env
```

The development configuration uses HTTP port `4010` and database host port `5442`.
Set credential variables only for the environments you will use.
Missing `${env:VAR}` references stop configuration loading.

## 3. Start the development server

```bash
mise run up
```

The task prepares dependencies, migrations, assets, and missing images.
It starts Phoenix in the foreground.
Open <http://127.0.0.1:4010>.

For a database-only task:

```bash
mise run db-up
mise run migrate
```

To run the manager and the worker as separate processes, use two terminals:

```bash
mise run up:manager
mise run up:worker
```

`up:manager` starts Phoenix in the manager role. It does not build agent images or run jobs.
`up:worker` builds missing images and polls the manager. It does not use the database.
Both tasks need the same `OMASHIKI_WORKER_TOKEN` value in `.env`.
The worker uses the Docker bridge gateway as the default manager URL.
Set `OMASHIKI_MANAGER_URL` to use a manager on a different host.

Use the [test procedure](how-to-run-tests.md) to validate source changes.

## 4. Install the repository hook

```bash
mise run hooks:install
```

The pre-push hook runs the same local CI script as `mise run ci`.
It can take longer than a focused test.

## 5. Stop local services

Press `Ctrl+C` in the server terminal.
Then run:

```bash
mise run stop
```

Keep the database volume when you need the existing queue and account state.
Do not use `up:fresh` unless you intend to delete local state.

Phoenix.Ecto.CheckRepoStatus is a request plug: while migrations are pending it
halts HTTP requests until you migrate. Start Postgres and apply migrations
before exercising the app:

```bash
mise run db-up
mise run migrate
```

The Ecto default in `config/dev.exs` is port `5432`. Local Compose publishes
Postgres on host port `5442` through `omashiki.toml` / `OMASHIKI_DB_PORT`.
The initial migration's `down` raises and tells you to use `mix ecto.reset`.
An existing development database from an older schema cannot be repaired by
migrate; use `mix ecto.reset` or `mise run up:fresh`. `e2e:prepare` runs
`MIX_ENV=test mix ecto.reset` against `omashiki_test` only and does not repair
`omashiki_dev`.

## Generated files

`omashiki.e2e.toml` is a generated, ignored test configuration.
Credential snapshots under `.omashiki/e2e/` are also local artifacts.
Do not commit either location.
The standard E2E runner uses a lock because preparation updates shared fixture files.
