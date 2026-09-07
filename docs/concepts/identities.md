# Agent identities

An agent can have a GitHub identity. You declare it in the house, on the
agent, next to the other things the agent has.

## Declare an identity

```toml
[identities.review-bot]
kind = "github-app"
app_id = "123456"
installation_id = "987654"
private_key = "${env:REVIEW_BOT_PRIVATE_KEY}"

[presets.reviewer]
plugin = "opencode"
identities = ["review-bot"]

[environments.review]
preset = "reviewer"
capabilities = ["github_*"]
# runtime, sink, credentials, ...
```

The rules:

- The key must be `${env:VAR}`. A literal key or an empty variable stops the
  boot.
- A preset that names an unknown identity stops the boot.
- Several presets can use the same identity.
- The environment has no `identities` field.

## How the agent uses it

While the job runs, the sandbox sees an MCP server named `review-bot`. The
tools are:

| Tool | Effect |
| --- | --- |
| `github_get_issue` | Read an issue or a pull request |
| `github_comment` | Comment on an issue or a pull request |
| `github_add_labels` | Add labels |
| `github_create_pull_request` | Open a pull request |

When the agent calls a tool, the **house** acts as the App. The house signs
the JWT, gets the installation token, and talks to GitHub. The sandbox and
the machine have only the token of the job.

The admitted environment carries the name, the kind, and the public ids.
The private key never leaves the house. If the house stops declaring the
identity, or declares it as a different App, the call is refused.

The `capabilities` list of the environment applies to these tools like to
any other MCP server. An environment without `github_*` cannot call them.

## Known limits

- The broker was tested against a simulated GitHub with a verified JWT, not
  against a real App.
- Only the `opencode` harness receives the MCP configuration that lists the
  identity. Claude and jcode do not see the `review-bot` server yet.

## Proof

- `server/test/omashiki/config/identity_test.exs`
- `server/test/omashiki/identities/broker_test.exs`
