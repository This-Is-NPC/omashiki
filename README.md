# Omashiki

> ### *Jobs, containers... and ~~chaos~~ worktrees.*

Omashiki is a local, durable queue runner for governed coding-agent jobs. It
admits work against registered repositories and environments, executes each
attempt in an isolated Docker container, and returns a clean committed Git
branch or a durable failure record.

The current harnesses are OpenCode over HTTP and Claude Code over a one-shot
CLI transport. Harness selection, images, mounts, resource limits, caches, and
network policy are declared in `omashiki.toml`; callers cannot select providers
or inject authentication through a job payload.

## Quick Start

Prerequisites:

- Docker with Compose support
- [mise](https://mise.jdx.dev/)

From the repository root:

```bash
mise install
mise run up
```

`mise run up` starts PostgreSQL, installs dependencies, applies migrations,
builds missing agent images, and starts Phoenix in the foreground. The checked-
in configuration serves the local operator UI at <http://127.0.0.1:4010> with
authentication disabled for local development.

Edit `omashiki.toml` to register repositories, harness profiles, environments,
credentials, caches, and limits. Configuration changes require a restart.

Install the bundled Agent Skill for compatible coding agents:

```bash
mise run skill:install
```

This copies the skill to `~/.agents/skills/omashiki/SKILL.md`. Run the command
again after updating Omashiki.

## Job Contract

The HTTP envelope uses `schema_version = 1`. Its `payload` field uses the
harness-neutral V2 payload contract:

```json
{
  "instruction": "Create hello.py and commit it.",
  "context": {
    "ticket": "EXAMPLE-123"
  }
}
```

`instruction` is required and `context` is an optional JSON object. Provider,
harness, model, and authentication controls are rejected from the payload.

## Validation

Install the versioned hook once per checkout:

```bash
mise run hooks:install
```

The `pre-push` hook and the manual command below execute the same local CI
script:

```bash
mise run ci
```

Run the opt-in real-provider E2Es separately:

```bash
mise run e2e:overture:opencode
mise run e2e:overture:claude
```

They use isolated local credential snapshots. See [Contributing](CONTRIBUTING.md)
for setup and credential-rotation details.

## Documentation

- [Documentation index and ownership](docs/README.md)
- [Product requirements](docs/prd.md)
- [Architecture](docs/architecture.md)
- [Current requirements](docs/requirements.md)
- [Data model](docs/data-model.md)
- [Contributing](CONTRIBUTING.md)
- [Agent images](agent/README.md)

Canonical product and system documentation lives under `docs/`. Files next to
components document only how to build, operate, or maintain that component.

## License

Omashiki is available under the [MIT License](LICENSE).
