# How to use Kata

Kata gives a sandbox a separate kernel through the Docker runtime handler.
Omashiki selects the handler through the environment's runtime field.

## Before you start

The execution host needs a working Kata installation and hardware virtualization support.
The Docker daemon must register a runtime named `kata`.
The configured agent image must exist on that host.

The repository includes a pinned host installer:

```bash
mise run kata:install
```

This command uses administrator privileges.
It validates the candidate Docker configuration and can restart Docker.
Schedule the installation when a Docker restart is acceptable.
See the [internal Kata reference](internal/runtime-kata.md) for installation details and compatibility checks.

## 1. Check the registered handler

```bash
docker info --format '{{json .Runtimes}}'
```

Check that the output includes `kata`.
If it does not, correct the host runtime installation before you change the environment.

## 2. Select the runtime

Inside the required environment section, set:

```toml
runtime = "docker.kata.debian"
```

Check the matching image catalog:

```toml
[runtimes.docker.kata.debian.images]
jcode = "omashiki/agent-jcode:latest"
```

Use the plugin key and image configured for your environment.
The client still submits only the environment name.

## 3. Check the workload

Submit a small job that uses the required files, network access, and credentials.
Inspect its result before you assign production work to that environment.
A successful runtime smoke test does not prove all workload requirements.

Kata compatibility remains incomplete for some mounts, sockets, credentials, and network configurations.
The [limitations page](what-does-not-work.md) identifies the current evidence boundary.
To return to runc, restore `runtime = "docker.runc.debian"` for new jobs.
