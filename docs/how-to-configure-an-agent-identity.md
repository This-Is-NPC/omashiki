# How to configure an agent identity

Use a GitHub App identity when the running agent must read, comment, label, or create a pull request.
The house performs these operations for the agent.

## Before you start

You need a GitHub App, its installation ID, and its private key.
The App needs permission for the operations you will allow.
You also need an OpenCode environment with working model access.
Only OpenCode currently receives the identity MCP configuration.

## 1. Declare the identity

Store the private key in an environment variable available to the house.
Add this declaration to `omashiki.toml`:

```toml
[identities.review-bot]
kind = "github-app"
app_id = "123456"
installation_id = "987654"
private_key = "${env:REVIEW_BOT_PRIVATE_KEY}"
```

Replace both IDs with your App values.
A literal private key in the TOML is refused.
An unset variable stops configuration loading.

## 2. Attach the identity to a preset

```toml
[presets.reviewer]
plugin = "opencode"
identities = ["review-bot"]
```

Add the identity to the preset, not the environment.
Several presets can use the same identity.
An unknown identity name stops configuration loading.

## 3. Allow the required tools

Add this field inside the existing environment section:

```toml
capabilities = ["github_*"]
```

The pattern permits all current GitHub identity tools.
Use individual capability names when the job needs fewer operations.

| Tool | Operation |
| --- | --- |
| `github_get_issue` | Read an issue or pull request. |
| `github_comment` | Add a comment. |
| `github_add_labels` | Add labels. |
| `github_create_pull_request` | Create a pull request. |

## 4. Submit a small task

Select the configured environment in a [job request](how-to-submit-a-job.md).
For the first check, ask the agent to read an issue.
Then inspect the result before you permit write operations.

The house keeps the App key and installation token.
The worker receives the identity name and public IDs.
The broker authorizes the admitted identity snapshot.
It refuses a request that does not match that snapshot.

The repository tests use a simulated GitHub service.
They do not prove that your real App permissions are correct.
See [known limitations](what-does-not-work.md).
