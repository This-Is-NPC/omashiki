# Omashiki documentation

The [project README](../README.md) describes Omashiki, use cases, and deployment options.
This index identifies the procedure or reference for each task.

## Start here

1. [Install and stop Omashiki](how-to-install-and-stop.md).
2. [Register a repository](how-to-register-a-repository.md).
3. [Configure an agent](how-to-configure-an-agent.md).
4. [Configure model access](how-to-configure-model-access.md).
5. [Submit a job](how-to-submit-a-job.md).
6. [Follow a job and retrieve its result](how-to-follow-and-retrieve-a-job.md).

Each procedure includes its prerequisites. Use names from your installation in place of the example names.
A job with a `files` or `none` sink can operate without a repository.

## Operate the installation

| Task | Procedure |
| --- | --- |
| Stop work or make another attempt | [Cancel and retry a job](how-to-cancel-and-retry-a-job.md) |
| Select the tasks and fields on the Home screen | [Customize task views](how-to-customize-task-views.md) |
| Accept work from GitHub or another tracker | [Connect an issue tracker](how-to-connect-an-issue-tracker.md) |
| Let an agent act as a GitHub App | [Configure an agent identity](how-to-configure-an-agent-identity.md) |
| Run jobs on another machine | [Add a worker](how-to-add-a-worker.md) |
| Give several houses access to one worker | [Share workers between houses](how-to-share-workers-between-houses.md) |
| Select the Kata runtime | [Use Kata](how-to-use-kata.md) |

To operate Omashiki from a coding agent, install the skill from the running house:

```bash
mkdir -p "${HOME:?}/.agents/skills/omashiki"
curl --fail-with-body -sS "$OMASHIKI_URL/api/v1/agent-skill" \
  > "${HOME:?}/.agents/skills/omashiki/SKILL.md"
```

The served skill is [`server/priv/agent_skill/SKILL.md`](../server/priv/agent_skill/SKILL.md).
A checkout copy lives at [`.agents/skills/omashiki/SKILL.md`](../.agents/skills/omashiki/SKILL.md) so a local agent loads the same text. That path is a Git symbolic link to the priv file. On Windows, enable Developer Mode (or run as Administrator) and clone with `git clone -c core.symlinks=true <url>`. Setting `core.symlinks` after clone does not convert an existing checkout; Git then writes a plain text file that contains only the target path. `GET /api/v1/agent-skill` always serves the priv file.

## References

- [Configuration](configuration.md): registry sections, paths, credentials, reloads, and worker settings.
- [Public API](api.md): authentication, requests, responses, events, and errors.
- [Security and limits](security-and-limits.md): access boundaries, output checks, and capacity limits.
- [What does not work](what-does-not-work.md): known limitations and available alternatives.
- [Example files](../examples/README.md): complete configuration and deployment files.

## Development

The [internal documentation](internal/README.md) contains development setup, tests, architecture, requirements, and implementation references.
