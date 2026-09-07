# How to configure model access

Select gateway access or a credential file from an authenticated agent installation.
The environment refers to credential names in the house registry.

## Gateway access

The house stores the provider API key.
The sandbox uses a temporary job token to call the house gateway.
The worker does not receive the provider API key.

1. Set the provider secret in the gitignored `.env` file.
2. Add the credential declaration to `omashiki.toml`.
3. Add its name to the environment's `credentials` list.

```toml
[credentials.provider-key]
provider = "openrouter"
model = "replace-with-your-model-id"
base_url = "https://openrouter.ai/api/v1"
api_key = "${env:OPENROUTER_API_KEY}"
```

Replace the model ID with one available to your provider account.
Use a plugin that supports gateway access, such as jcode.
The [single-node example](../examples/single-node.omashiki.toml) contains a complete commented jcode configuration.

The worker and sandbox must reach the house gateway.
Do not use `network = "none"` for a gateway-only agent.

## Host credential access

Authenticate the selected agent on each execution machine.
Use the same operating-system account that runs the worker.
Declare the credential origin in the house:

```toml
[host_credentials.claude-local]
kind = "claude-code"
credentials = "~/.claude/.credentials.json"
```

Add `claude-local` to the Claude environment's `credentials` list.
For OpenCode or Codex, use the matching declaration in the [configuration example](../omashiki.toml).

The worker expands `~/` against its own process home.
The house keeps the original path form in the job snapshot.
Absolute paths are permitted. Relative paths such as `./auth.json` are refused.

Each attempt receives a private credential copy.
A token refresh can update that copy.
Omashiki does not copy the change back to the source credential file.
If authentication expires, authenticate the agent again on the execution machine.

## Check access

[Submit a small job](how-to-submit-a-job.md) with the configured environment.
If startup reports a missing variable, set that variable before you restart the house.
If execution reports a missing credential file, check the path on the worker.
If the provider refuses authentication, check the account and credential source.

See [security and limits](security-and-limits.md) for the credential boundaries.
