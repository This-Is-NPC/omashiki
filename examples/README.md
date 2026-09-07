# Example files

Use these files with the [configuration reference](../docs/configuration.md).
Replace example paths, registered names, and secrets with your installation values.

| File | Purpose |
| --- | --- |
| [single-node.omashiki.toml](single-node.omashiki.toml) | One embedded house and execution machine. |
| [multi-node.omashiki.toml](multi-node.omashiki.toml) | Embedded nodes sharing PostgreSQL and canonical Git remotes. |
| [compose.manager.yml](compose.manager.yml) | Manager release with its own database. |
| [compose.worker.yml](compose.worker.yml) | Worker release with host Docker access. |
| [worker.toml](worker.toml) | Worker limits and Docker settings. |
| [handler/github_issue_handler.py](handler/github_issue_handler.py) | Labelled GitHub issue admission and signed terminal callback verification. |
| [loadtest.omashiki.toml](loadtest.omashiki.toml) | Test registry declarations for the internal load-test procedure. |

## Select a deployment

For one machine, follow [install and stop](../docs/how-to-install-and-stop.md).
For separate roles, follow [worker setup](../docs/how-to-add-a-worker.md).
For shared execution, follow [multiple houses](../docs/how-to-share-workers-between-houses.md).

The root `omashiki.toml` is tracked by Git.
Use `${env:VAR}` references for supported secret fields.
Keep actual secret values in the gitignored `.env` file.

## Agent clients

The bundled Agent Skill operates the public HTTP API.
Install it with `mise run skill:install`.

[mcp.json.example](mcp.json.example) records a possible client configuration shape only.
Omashiki has no public MCP endpoint.
Do not install that example as `.mcp.json` for an existing installation.

Internal MCP code serves job tools through the house.
It does not provide the client API shown by that example.

## Development examples

Use [load-test setup](../docs/internal/how-to-run-load-tests.md) for test tiers.
Use [development setup](../docs/internal/how-to-set-up-development.md) for generated E2E configuration and credential snapshots.
