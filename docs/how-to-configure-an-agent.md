# How to configure an agent

A preset selects the agent plugin.
An environment selects the preset and the execution policy.
A client submits the environment name with its instruction.

## Before you start

You need access to the house registry.
The selected plugin image must exist on each execution machine.
The built-in plugins are `opencode`, `claude-code`, `codex`, `pi`, and `jcode`.

## 1. Select a preset

The single-node example contains an OpenCode preset.
To add a separate preset, use a unique name:

```toml
[presets.reviewer]
plugin = "opencode"
```

Plugin-specific settings belong in `options`.
Use the corresponding file in [plugins](../plugins) to check supported option names.
Do not put `runtime`, `image`, or `credentials` on a preset.

## 2. Add the environment

This example uses the `opencode-local` credential from the single-node configuration:

```toml
[environments.review]
preset = "reviewer"
runtime = "docker.runc.debian"
sink = "git"
packages = []
executables = ["git"]
credentials = ["opencode-local"]
caches = []
timeout_ms = 900000
network = "restricted"
mounts = []
pre_steps = []
post_steps = []

[environments.review.resources]
cpus = 1.0
memory = "1GB"
pids = 256
```

The environment needs a repository because its sink is `git`.
Select `files` for an output archive, or `none` for completion metadata.
See [configuration](configuration.md#result-sinks) for the result rules.

Add only the executables, mounts, caches, and network access that the job needs.
A pre-step or post-step uses an argument array with a declared executable.
The job payload cannot change this policy.

## 3. Configure model access

Follow [model access](how-to-configure-model-access.md).
A valid environment name does not prove that its credential file or provider account works.

## 4. Check the environment

```bash
curl --fail-with-body -sS \
  -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/environments"
```

Check the environment name, plugin, runtime, and resource values in `data`.
If validation fails, correct the reported registry field.
Next, [submit a job](how-to-submit-a-job.md).
