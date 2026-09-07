# Model access: gateway or subscription

An agent needs a model. There are two ways to pay for it. The key never
lives on the machine.

## Gateway

The `api_key` stays in the house. The container gets a token for this job
and talks to the gateway of the house. The machine has no key file.

## Subscription

Harnesses with a login (`claude-code`, Codex, OpenCode host auth) use a file
on the **machine**. You declare the file in the house as `host_credentials`:

```toml
[host_credentials.claude-local]
kind = "claude-code"
credentials = "~/.claude/.credentials.json"
```

The rules:

- The house does not expand `~/` when it loads the file. The path travels
  in the declared form.
- The machine that copies the file expands `~/` to the home of the process
  that runs Docker. The operator did `claude login` as the user that runs
  the worker. The developer does not travel.
- Absolute paths pass as they are.
- `./` and `../` are refused.
- If the file is missing on that machine, the attempt fails. The machine
  does not look in another place.
- `worker.toml` never has credentials.

| | Gateway | Subscription |
| --- | --- | --- |
| Where the key lives | House | File on the machine, declared in the house |
| In the container | Token for this job | Copy for this attempt in `/run/omashiki/state` |
| Permanent on the machine | No | Only the login of the machine |
| House not reachable | Refuse | Refuse |

## Proof

`server/test/omashiki/runtime/host_credentials_test.exs`
