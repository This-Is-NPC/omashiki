# How to build agent images

Agent images contain the tools that run inside job containers.
The environment selects an image through its runtime catalog and preset plugin.

## Before you start

You need Docker access and the pinned build tools.
Run commands from the repository root.
Check the required plugin version in its Dockerfile before you change a pin.

## 1. Build the selected image

| Plugin | Build command | Dockerfile |
| --- | --- | --- |
| OpenCode | `mise run agent:build` | `agent/Dockerfile` |
| Claude Code | `mise run agent:claude:build` | `agent/Dockerfile.claude` |
| Codex | `mise run agent:codex:build` | `agent/Dockerfile.codex` |
| pi | `mise run agent:pi:build` | `agent/Dockerfile.pi` |
| jcode | `mise run agent:jcode:build` | `agent/Dockerfile.jcode` |

To build missing images from the configured catalog:

```bash
mise run images
```

The build task and catalog must agree on the image tag.
Distribute the required image to every execution host before you select it in a job.

## 2. Preserve the runtime contract

The runtime supplies the workspace, process IDs, mounts, temporary storage, and resource limits.
Do not add a Docker socket mount or arbitrary shell evaluation to an image entrypoint.
Keep provider credentials outside the image.
Use the declared invocation file instead of placing the instruction in process arguments.

| Plugin | Entrypoint behavior |
| --- | --- |
| OpenCode | Start its HTTP server. Readiness checks `/doc`. |
| Claude Code | Prepare isolated credential state. Run turns through the fixed runner. |
| Codex | Prepare isolated `auth.json`. Run turns through the fixed runner. |
| pi | Use the declared CLI transport and output decoder. |
| jcode | Require the gateway URL, model, and job token before startup. |

Images use a temporary agent home.
Claude and Codex can update only their explicit per-attempt credential file.
The host credential directory is not mounted into the sandbox.

The jcode image has a smaller dependency contract.
It includes Python but does not include mise or curl at runtime.
Do not add those tools without updating the image checks and environment requirements.

## 3. Check the image

Run the applicable `ci:docker:<plugin>` task.
For OpenCode, the task name is `ci:docker:agent`.
For Claude Code, it is `ci:docker:claude`.
Use `ci:docker:codex`, `ci:docker:pi`, or `ci:docker:jcode` for the other images.

```bash
mise run ci:docker:jcode
```

Then run a deterministic job with the changed image.
Use [the test procedure](how-to-run-tests.md) to select the appropriate E2E.
For shared-cache changes, also run `mise run agent:cache-smoke`.
