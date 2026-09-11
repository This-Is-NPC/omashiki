# Configuration reference

The house reads its registry from `omashiki.toml`.
A worker reads machine settings from `worker.toml`.
Use the [example files](../examples/README.md) for complete configurations.

## Terms

| Term | Meaning |
| --- | --- |
| House | The service that owns a queue, registry, credentials, and results. |
| Manager | The process role that runs the house without local job execution. |
| Worker | The process role that runs jobs for enrolled houses. |
| Embedded | The process role that runs the house and local execution together. |
| Plugin | The manifest that defines how an agent tool starts and returns output. |
| Preset | A named plugin configuration with optional agent identities. |
| Environment | A named execution policy that selects one preset. |
| Sink | The environment setting that selects the result type. |
| Snapshot | The resolved configuration captured when the house admits a job. |

Use these terms consistently in requests and documentation.

## House sections

| Section | Main settings |
| --- | --- |
| `[app]` | HTTP host and port. |
| `[db]` | Database connection settings used by local tasks. |
| `[auth]` | Browser and API authentication mode. |
| `[reload]` | Registry reload mode and drain timeout. |
| `[limits]` | Local container capacity and default resource limits. |
| `[nodes.<name>]` | Declared embedded nodes in a shared-database deployment. |
| `[repositories.<name>]` | Git remote or local path, base branch, and Git access settings. |
| `[presets.<name>]` | `plugin`, `options`, and `identities`. |
| `[environments.<name>]` | Preset, runtime, sink, credentials, network, mounts, steps, and resources. |
| `[credentials.<name>]` | Provider, model, API key, and gateway upstream URL. |
| `[host_credentials.<name>]` | Agent credential kind and source file paths. |
| `[identities.<name>]` | GitHub App identity and private-key reference. |
| `[caches.<name>]` | Cache path, size, environment variables, and package policy. |
| `[runtimes.docker.<handler>.debian.images]` | Plugin keys mapped to Docker image tags. |

For infrastructure values, process environment overrides take precedence over TOML values.
Execution declarations come from the registry.
A job payload cannot add registry declarations.

## Environment settings

| Field | Meaning |
| --- | --- |
| `preset` | Name of one declared preset. |
| `runtime` | `docker.runc.debian` or `docker.kata.debian`. |
| `sink` | `git`, `files`, or `none`. |
| `credentials` | Names from gateway or host credential declarations. |
| `capabilities` | Allowed tool capabilities, including declared identity tools. |
| `packages` | Packages available through the declared environment setup. |
| `executables` | Commands permitted in configured lifecycle steps. |
| `caches` | Names of declared caches. |
| `timeout_ms` | Maximum attempt time in milliseconds. |
| `network` | Network policy, including `none`, `restricted`, or explicit `host` access. |
| `mounts` | Declared host-to-container file mounts. |
| `pre_steps`, `post_steps` | Ordered commands before and after the agent turn. |
| `resources` | CPU, memory, and PID limits. |
| `policy` | Package policy mode and related settings. |
| `mcp_servers` | Declared tool server URLs and headers. |

A lifecycle step uses `argv`, `condition`, and `timeout_ms`.
Commands must use declared executables.
Do not put shell command strings in place of argument arrays.

## Result sinks

| Sink | Repository | Output |
| --- | --- | --- |
| `git` | Required. | Verified branch with base and head revisions. |
| `files` | Optional. | Validated archive with a digest and manager storage metadata. |
| `none` | Optional. | Completion metadata. No published Git branch or archive. |

Git admission requires `payload.title` or `payload.branch`.
The title becomes a branch name after normalization.
An explicit branch must pass Git reference validation.
A title cannot contain `/`.

A successful `none` result does not prove that a particular external action occurred.
Check the external system when that action matters.

## Paths and secrets

A repository path must be inside the configuration root or the managed mirror root.
It must be a real Git repository without symlink components.
Use a remote declaration for other repositories.

Credential origins must be absolute paths or start with `~/`.
The execution machine expands `~/` against its process home.
The worker copies the origin for each attempt.
It does not write refreshed credentials back to the origin.

Use `${env:VAR}` for secret values in supported fields.
These fields include `api_key`, `base_url`, `ssh_key_passphrase`, and identity `private_key`.
A missing or empty referenced variable stops configuration loading.
Identity private keys and SSH passphrases require the reference form.

## Split the registry

The root file can include files or directories:

```toml
include = ["identities", "presets/reviewer.toml"]
```

Included paths must stay inside the house directory.
Only registry sections can move into included files.
These sections are `identities`, `presets`, `environments`, `credentials`, `host_credentials`, `repositories`, and `caches`.
Infrastructure sections remain in the root file.
An included file cannot include another file.
Duplicate declaration names stop loading. Later files do not override earlier files.

## Reload behavior

A registry reload changes admission for new jobs.
An admitted job retains its captured configuration.
Infrastructure changes require a process restart.

| Mode | Behavior |
| --- | --- |
| `gradual` | Apply the registry while active attempts continue with their snapshots. |
| `drain_all` | Pause admission and wait for active attempts before the registry change. |

`drain_timeout_ms` limits the drain wait.
If the timeout expires, the reload is abandoned and admission resumes.
A configuration reload does not cancel user work.

## Task views file

The browser Home screen reads a separate `ui.toml` file.
This file is not part of the registry. A registry reload does not read it.
An incorrect views file does not stop the house or change a job.
See [customize task views](how-to-customize-task-views.md).

## Worker settings

The [worker example](../examples/worker.toml) contains only `[limits]` and `[docker]`.
The enrollment state stores manager IDs, URLs, and worker tokens.
It does not contain the house database or provider keys.

| Variable | Purpose |
| --- | --- |
| `OMASHIKI_ROLE` | Select `embedded`, `manager`, or `worker`. |
| `OMASHIKI_NODE` | Select the execution machine ID. |
| `OMASHIKI_WORKER_CONFIG` | Select the worker settings file. |
| `OMASHIKI_WORKER_STATE_PATH` | Select the persistent enrollment state file. |
| `OMASHIKI_ENROLL_SECRET` | Authenticate enrollment requests to the worker. |
| `OMASHIKI_WORKER_TOKEN` | Authenticate worker requests to a manager. |
| `OMASHIKI_MANAGER_URL` | Manager URL used by the enrollment task. |
| `OMASHIKI_WORKER_URL` | Worker listener URL used by the enrollment task. |
| `OMASHIKI_HOST_HOME` | Host path used by the worker Compose mounts. |

Follow [worker setup](how-to-add-a-worker.md) for URL selection and deployment commands.
