# GitHub issue triage

This recipe runs an agent on each new issue of one GitHub repository.
The agent reads the issue and adds labels.
It comments with a short summary and leaves a real report open.
It closes a joke or troll issue as not planned.

The agent acts on GitHub as a GitHub App through the house.
The job has no repository, no code, and no result to deliver.

| File | Purpose |
| --- | --- |
| [triage.toml](triage.toml) | Identity, preset, and `triage` environment. |
| [triage.md](triage.md) | The instruction that precedes each issue. |
| [run.sh](run.sh) | Starts the reference handler and an optional webhook relay. |

## Before you start

You need a house that runs from this checkout. See [install and stop](../../docs/how-to-install-and-stop.md).
The house needs working OpenCode model access. See [model access](../../docs/how-to-configure-model-access.md).
The environment uses the `opencode-local` host credential from the root `omashiki.toml`.
Declare it if your root file does not.
You need admin access to one GitHub repository.
The relay step uses `npx`, which Node.js provides.

## 1. Create the GitHub App

On GitHub, open **Settings**, **Developer settings**, **GitHub Apps**, and **New GitHub App**.
Give the App a name and a homepage URL.
Clear **Active** under **Webhook**. The repository webhook in step 5 sends the events.
Under **Repository permissions**, set **Issues** to **Read and write**.
Create the App.

Note the **App ID** on the App page.
Generate a private key. GitHub downloads a `.pem` file.
Install the App on the one repository that you want to triage.
The installation ID is the number at the end of the installation page URL.

Put the App ID and installation ID in [triage.toml](triage.toml), in place of the example values.

## 2. Include the recipe

Add this line at the top of the root `omashiki.toml`, before the first section:

```toml
include = ["examples/github-triage/triage.toml"]
```

The path is relative to the root file.
An included file must be inside the root file's directory.
See [split the registry](../../docs/configuration.md#split-the-registry) for the other rules.

## 3. Start the house

The house reads the private key from `TRIAGE_BOT_PRIVATE_KEY`.
The `restricted` environment needs a Docker network for OpenCode.
Set both variables in the terminal that starts the house:

```bash
export TRIAGE_BOT_PRIVATE_KEY="$(cat /path/to/your-app.private-key.pem)"
export OMASHIKI_AGENT_NETWORK_MODE=bridge
mise run up
```

Restart the house if it already runs. It must see the new variables.
An unset key variable stops configuration loading and names the variable.

## 4. Check the installation

In another terminal, from the repository root, set the same two variables and run the doctor:

```bash
export TRIAGE_BOT_PRIVATE_KEY="$(cat /path/to/your-app.private-key.pem)"
export OMASHIKI_AGENT_NETWORK_MODE=bridge
mise run doctor
```

The doctor loads `omashiki.toml` itself, so it needs the key variable too.
In an installation from the release image, run `bin/doctor` in the house container.
See [check the installation](../../docs/how-to-install-and-stop.md#4-check-the-installation).

The doctor checks the network of the `triage` environment and the GitHub App identity.
Correct each `error` with its fix before you continue.

## 5. Connect GitHub

Issue a token that can submit jobs to the `triage` environment only:

```bash
cd server
mix omashiki.token create --name github-triage --env triage --scopes read,submit
cd ..
```

The task prints the token once. Keep it for step 6.
In an installation from the release image, run `bin/token` with the same arguments in the house container.
See [API authentication](../../docs/api.md#authentication).

GitHub must reach the handler.
On a machine without a public address, use a relay such as [smee.io](https://smee.io).
Open <https://smee.io/new> and copy the channel URL.

Create a webhook secret, for example with `openssl rand -hex 32`.
On the repository, open **Settings**, **Webhooks**, and **Add webhook**:

| Field | Value |
| --- | --- |
| Payload URL | The smee.io channel URL, or the handler's public `/github` URL. |
| Content type | `application/json` |
| Secret | The webhook secret. |
| Events | **Let me select individual events**, then **Issues** only. |

## 6. Run the handler

From the repository root:

```bash
read -rs -p 'Omashiki token: ' OMASHIKI_TOKEN; echo
read -rs -p 'GitHub webhook secret: ' GITHUB_WEBHOOK_SECRET; echo
export OMASHIKI_TOKEN GITHUB_WEBHOOK_SECRET
export SMEE_URL=https://smee.io/your-channel
examples/github-triage/run.sh
```

The script refuses to start without the token or the webhook secret.
With `SMEE_URL` set, it also starts the smee.io client.
Without it, point the webhook at the handler's public `/github` URL.
`OMASHIKI_URL` defaults to `http://127.0.0.1:4010`. `HANDLER_PORT` defaults to `8090`.

The handler accepts only `issues.opened` events.
It puts [triage.md](triage.md) before the issue title and body.
It sends no repository, because a `none` job takes none.

## 7. Open an issue

Open a new issue in the repository.
The handler logs `admitted job` with the job ID.

The Home board at <http://127.0.0.1:4010> shows the task `issue-<number>-<title>`.
The task ends as succeeded when the agent finishes.

On GitHub, a real report gets labels such as `bug` or `question` and a summary comment. It stays open.
A joke gets the labels `troll` and `invalid`, a short reply, and is closed as not planned.
The App is the author of the labels, the comment, and the close.

## If it fails

Run `mise run doctor` first. It reports most setup problems with a fix.

| Condition | Action |
| --- | --- |
| No job appears | Check that the relay runs and the handler logs the delivery. A `401` from the handler means the webhook secrets differ. |
| The handler logs `omashiki rejected the job` | Read the problem code. Check that the token allows the `triage` environment. |
| The job fails | Open the task on the Home board. The details show the error code, message, and failing step. |
| The job fails with `harness_unreachable_no_network` | Set `OMASHIKI_AGENT_NETWORK_MODE` for the house. Restart it. |
| The job succeeds but nothing changes on GitHub | Check that the App has **Issues: Read and write** and is installed on the repository. |

The same error is in `GET /api/v1/jobs/<id>`. See [follow a job](../../docs/how-to-follow-and-retrieve-a-job.md).
The recipe sets no terminal webhook, so the house does not notify the handler when the job ends. The agent's work is on GitHub.
To receive that notification on this local handler, set `[webhooks] allow_private_destinations = true` in `omashiki.toml`.
Then set the token's webhook to `http://127.0.0.1:8090/omashiki`. See [the return path](../../docs/how-to-connect-an-issue-tracker.md#3-configure-the-return-path).
For the tools and the identity model, see [agent identity](../../docs/how-to-configure-an-agent-identity.md).
