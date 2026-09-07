# How to register a repository

Use this procedure before you submit a job with a `git` sink.
The house must declare the repository before a client can select it.

## Before you start

You need a running house and access to its `omashiki.toml` file.
You also need the repository URL and base branch.

## 1. Add the repository

Add this section to `omashiki.toml`:

```toml
[repositories.my-service]
remote = "git@github.com:example/my-service.git"
base_branch = "main"
```

Replace the URL and branch with your repository values.
The client will select the name `my-service`.
Omashiki creates a mirror under `~/.cache/omashiki/mirrors`.

For a private SSH remote, configure Git access on each execution machine.
The machine must read the remote and publish the result branch without an interactive prompt.
The sandbox does not receive the machine's push key.

For a repository inside the configuration root, you can use a local path:

```toml
[repositories.local-project]
path = "."
base_branch = "master"
```

The path must already contain a Git repository.
Use the actual base branch of that repository.
A path outside the configuration root or mirror root is refused.
Symlink components are also refused.

Use a canonical remote when several machines execute jobs.
A local-only result remains on the machine that produced it.

## 2. Check discovery

Use the [API authentication procedure](api.md#authentication) to obtain a token.
Set `OMASHIKI_URL` and `OMASHIKI_API_TOKEN` in your shell.

```bash
curl --fail-with-body -sS \
  -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/repositories"
```

The response contains a `data` array.
Check that your repository name and base branch appear there.
If the name is missing, check the registry reload error.

Next, [configure an agent](how-to-configure-an-agent.md).
