# How to add a plugin

A plugin manifest defines transport, options, startup, invocation, and output decoding.
A preset supplies option values. An environment supplies execution policy.

## Before you start

Read the [architecture](architecture.md) and [design decisions](design-decisions.md).
Select an existing manifest with a similar transport.
Use `plugins/jcode.toml` for a simple CLI example.
Use `plugins/opencode.toml` for the HTTP transport.

## 1. Define the manifest

Create `plugins/<name>.toml`.
The filename supplies the plugin name.
The loader reads TOML files from the plugin directory.

Define the required sections:

| Section | Purpose |
| --- | --- |
| `transport` | Select the supported CLI or HTTP transport. |
| `prepare` | Select a supported preparation path. |
| `readiness` | Define the readiness command or HTTP check. |
| `options` | Declare accepted types, defaults, and path restrictions. |
| `argv` and `option_argv` | Define argument arrays and conditional arguments. |
| `env` | Define the container process environment. |
| `files` | Define generated invocation files. |
| `output` | Select the supported output shape and field mapping. |
| `requires.binaries` | Declare binaries required by the plugin. |

Use literal template substitution only.
Do not add shell execution or expressions to a template.
Do not select provider credentials from the job payload.

If the tool requires an unsupported output shape, extend the decoder with focused tests.
Keep transport mechanics separate from job admission and Docker policy.

## 2. Provide the image

[Build an image](how-to-build-agent-images.md) containing the tool and its runner.
Add the plugin key to the applicable runtime image catalog.
The image or declared packages must provide every required binary.
The production configuration check inspects that requirement through Docker.

## 3. Add a preset and environment

Declare `[presets.<name>]` with the new plugin name.
Declare an environment that selects the preset and runtime.
Use [agent configuration](../how-to-configure-an-agent.md) as the operator example.
Keep credentials, caches, network access, and resources on the environment.

## 4. Test the integration

Add tests for valid and invalid manifest options.
Check argument expansion, invocation files, output decoding, and usage mapping.
Check that prompts and secrets do not enter logs or command arguments.
Test missing binaries and failed readiness.
Test timeout, cancellation, and cleanup through the runtime boundary.

Run a deterministic job before a real-provider test.
Record provider-specific prerequisites in the relevant procedure.
Do not claim identity MCP support unless the integration actually supplies that configuration.

## Snapshot requirement

Admission stores the resolved plugin and its digest with the job.
A worker must execute that admitted definition.
A later manifest edit must not change queued or active admitted work.
