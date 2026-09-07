# The house registry

The house is one TOML file, `omashiki.toml`. It declares what the house can
run. A client that sends work selects only the **name** of an environment.
The house knows what that name means.

## The graph

```
plugin        → how the tool runs
identity      → who the agent is (for example a GitHub App)
preset        → the agent (plugin + identities)
environment   → the box (runtime, network, credentials, MCP servers)
repository    → the git repository
```

The rules:

- `environment.preset` points to exactly one preset.
- `preset.identities` points to zero or more identities.
- `environment.credentials` points to names in `credentials` or in
  `host_credentials`.
- The environment does **not** point to identities. The face is on the
  agent, not on the box.
- An MCP server for Jira or another tracker is `url` + `headers` on the
  environment. It is a pipe. An identity is who the agent is.

The machine file, `worker.toml`, is a different tree. It has only `limits`
and `docker`. It has no identities, no credentials, and no `include`.

## One file or many files

The root file can list `include`:

```toml
# omashiki.toml (root)
include = ["identities", "presets/reviewer.toml"]

[app]
# [db] [auth] [reload] [runtimes] [limits] [nodes] always stay in the root
```

Each entry is a file or a directory of `*.toml` files inside the house
directory. The rules:

- Depth is one. A piece cannot include another piece.
- Only `identities`, `presets`, `environments`, `credentials`,
  `host_credentials`, `repositories`, and `caches` can leave the root.
- The same name in two places stops the boot. No file wins.
- The digest is of the united snapshot. If you split the file, the digest
  does not change.

## Secrets

Secrets never go in `omashiki.toml`. The file is in git. The fields
`api_key`, `base_url`, `ssh_key_passphrase`, and `private_key` accept
`${env:VAR}`. The house resolves the variable when it loads the file. An
unset variable stops the boot and names the variable.

## Hot reload

The registry reloads without a restart. Infrastructure settings (`[app]`,
`[db]`, `[auth]`, `[limits]`) need a restart. A job keeps the snapshot it
was admitted with. A reload cannot change a running job.

## Examples and proof

- Registries: [examples/](../../examples/README.md)
- Tests: `server/test/omashiki/config/include_test.exs`
