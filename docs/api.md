# Public API reference

The public API uses the `/api/v1` prefix.
The live contract is `GET /api/v1/openapi.json`.
Do not keep a generated copy of that document in the repository.

Errors use `application/problem+json` (RFC 9457).
Each error body has `type`, `title`, `status`, `code`, `detail`, `errors`, and `request_id`.
The `code` values are the enum in the OpenAPI Problem schema.

## Authentication

On the house machine, issue a token with the token tool.
In a checkout, run the `omashiki.token` Mix task from `server/`:

```bash
cd server
mix omashiki.token create --name local-client --env '*' --scopes read,submit,cancel
```

In an installation from the release image, run `bin/token` in the house container with the same arguments.
With the [manager Compose file](../examples/compose.manager.yml):

```bash
docker compose -f examples/compose.manager.yml exec manager \
  bin/token create --name local-client --env '*' --scopes read,submit,cancel
```

The tool prints the plaintext token once.
With `[auth] enabled = false`, the tool acts as the local operator.
With authentication enabled, add `--user` with an operator's username or email.
`--max-active` sets `max_active_jobs` (default 10).
`--ttl-days` sets the lifetime (default 30).

`mix omashiki.token list` (`bin/token list` in the image) shows the operator's tokens.
`mix omashiki.token revoke ID` (`bin/token revoke ID` in the image) revokes one.
The Config screen lists the same tokens and can also create and revoke them.

From another machine, use an existing operator account to request a token.
Write the credentials to a private temporary file:

```bash
export OMASHIKI_URL=http://127.0.0.1:4010
umask 077
cat > /tmp/omashiki-login.json <<'JSON'
{
  "username": "replace-with-your-username",
  "password": "replace-with-your-password",
  "name": "local-client",
  "scopes": ["read", "submit", "cancel"],
  "allowed_environments": ["*"],
  "max_active_jobs": 100,
  "ttl_days": 30
}
JSON
```

Replace the example credentials in that file.
Then request a token:

```bash
curl --fail-with-body -sS -H 'Content-Type: application/json' \
  --data-binary @/tmp/omashiki-login.json \
  "$OMASHIKI_URL/api/v1/sessions/issue_token" > /tmp/omashiki-token.json
OMASHIKI_API_TOKEN=$(jq -er '.data.token' /tmp/omashiki-token.json)
export OMASHIKI_API_TOKEN
```

Remove the temporary credential and token files after you store the token securely.
The server returns the plaintext token once.
Send it in `Authorization: Bearer <token>`.
Do not send tokens in query parameters.

For a house without an operator, `/sessions/signup` requires the same token grants plus `email`, `username`, and `password`.
It returns HTTP `201` with the first token.
Signup returns `409` after an operator exists.
Token issuance returns `200`, invalid credentials return `401`, and rate limiting returns `429`.
An expired token returns `401` with `code` `token_expired`.
Authenticated responses include `x-token-expires-at`.

Scopes are `read`, `submit`, `cancel`, and `review`.
Submit, retry, and webhook redeliver require `submit`.
Cancellation requires `cancel`.
Approving and rejecting output held for review require `review`.
Listing, inspection, events, and results require `read`.
Grant `review` only to a client trusted to publish output in which gitleaks found secrets.
A token that lacks a required scope receives `403` with `code` `insufficient_scope`.

`allowed_environments` is a non-empty list of environment names, or `["*"]` for every registered environment.
`max_active_jobs` is the number of non-terminal jobs that token may hold.

Local authentication-disabled mode does not remove the token requirement for job submission.
Use `mix omashiki.token create`, or `bin/token create` in the release image, to get a token in that mode.
Use the submitting token for job inspection and result access.

## Agent skill

```bash
mkdir -p "${HOME:?}/.agents/skills/omashiki"
curl --fail-with-body -sS \
  "$OMASHIKI_URL/api/v1/agent-skill" \
  > "${HOME:?}/.agents/skills/omashiki/SKILL.md"
```

The served file is the versioned skill with the installation URL filled in.
The skill points at `/api/v1/openapi.json` for routes and schemas.

## Discovery

`GET /repositories` lists the registered repositories with `name` and `base_branch`.
`GET /environments` lists the registered environments.
Both require the `read` scope.

```json
{
  "data": [
    {
      "name": "opencode",
      "sink": "git",
      "preset": "opencode",
      "plugin": "opencode",
      "runtime": "docker.runc.debian",
      "handler": "runc",
      "backend": "docker",
      "distribution": "debian",
      "image": "omashiki/agent:latest",
      "timeout_ms": 1800000,
      "network": "restricted",
      "secret_scan": "review",
      "capabilities": [],
      "resources": {"cpus": 2.0, "memory": "2GB", "pids": 256}
    }
  ]
}
```

`sink` is `git`, `files`, or `none`.
It decides whether a job for that environment takes `repo`:

| `sink` | `repo` in the job request |
| --- | --- |
| `git` | Required. Use a name from `GET /repositories`. |
| `files` | Omit it. A request with `repo` is rejected. |
| `none` | Omit it. A request with `repo` is rejected. |

[Result sinks](configuration.md#result-sinks) describes the output of each sink.
`secret_scan` is `review` or `block`: whether output with a secret waits for review or fails the job.

## Wait and listing

`GET /jobs/{id}/result?wait=60` holds the connection until the job is terminal or the wait expires, to a maximum of 60 seconds.
HTTP `202` with `retry-after` means the job is still running.
HTTP `409` with `code` `result_not_ready` means the caller did not supply `wait` and the job is not terminal.

A successful result includes `summary`, `changes` (`files_changed`, `insertions`, `deletions`, `files`), and `compare_url` when the remote is GitHub or GitLab.

`GET /jobs` pages with an opaque `cursor` and returns `next_cursor`.
The page size is 50.
Filter by `status`, `environment`, `repository`, `worker`, `correlation_id`, and `since`.
An unknown `status` value returns HTTP `422` with `code` `invalid_status`.

## Review held output

A job in status `review` holds output in which gitleaks found secrets, and no other output check failed.
Its `review` object in `GET /jobs/{id}` has:

| Field | Meaning |
| --- | --- |
| `error` | The `secret_found` error that a rejection records. `error.details.findings` lists the findings, as in [job errors](#job-errors). |
| `node` | The node that holds the output. |
| `decision` | `null` until a decision, then `approve` or `reject`. |
| `decided_by`, `decided_at` | Who decided, and when. |

The object stays on the job after the decision.
A retry clears it.

`POST /jobs/{id}/approve` publishes the output.
The job stays in `review` until the node that holds the output publishes it, then becomes `succeeded`.
If publishing fails, the job fails with the publishing error.
Approving again returns the job unchanged.

`POST /jobs/{id}/reject` fails the job at once with its `secret_found` error, and the node removes the output.

Both require the `review` scope and return the job.
A job that is not in `review` returns `409` with `code` `invalid_transition`.
`POST /jobs/{id}/cancel` also works on a job in review, and the node removes the output.
[Output checks](security-and-limits.md#output-held-for-review) explains where the output waits.

Allowing a finding for later jobs is an operator action on the Home and Config screens.
The API does not create or remove allowances: an allowance changes the secret scan for every token's jobs in an environment, and a token only acts on its own jobs.

The job emits a `job.review` event with `error_code` and `error_message` when it enters review.
The webhook comes when the job ends.

## Job errors

A `failed` or `cancelled` job has an `error` object in `GET /jobs/{id}` and in its result.
The object has a stable `code`, a readable `message`, and structured `details`.
`details.step` names the step that failed.
`details.reason` keeps the internal reason.

| Code | Cause |
| --- | --- |
| `docker_error` | Docker refused a container request. The message repeats the Docker message. |
| `bootstrap_failed` | The container startup command failed. `details` has the exit code and output. |
| `harness_not_ready` | The agent harness did not pass its readiness check in time. |
| `harness_unreachable_no_network` | An HTTP harness runs in a container without a network. |
| `harness_exit` | The agent harness exited with a non-zero code. |
| `agent_waiting_for_permission` | The agent or one of its subagents asked for an approval. `details` has the permission, its patterns, and `subagent`. |
| `secret_found` | gitleaks found secrets in the output, which was not published: the environment blocks such output, or an operator rejected it. The message names up to three findings. `details.findings` lists up to 50, each with `file`, `line`, `rule_id`, `description`, a `match` with the secret replaced by `REDACTED`, and a `fingerprint` that identifies the secret in that file under that rule. `details.finding_count` counts them all. Allowed findings are not listed. |
| `protected_path` | The output writes under `.git/`, `.ssh/`, or `.aws/`. `details.path` names the file. |
| `symlink_path` | The output contains a symbolic link. `details.path` names it. |
| `oversized_output` | The output changes more than the size limit. `details` has `changed_bytes` and `max_bytes`. |
| `secret_scan_unavailable` | gitleaks was missing or failed, so the output could not be scanned and was not published. |
| `timeout` | A call to Docker or to the harness did not finish in time. |
| `stale_attempt` | The attempt stopped renewing its lease. |
| `cancelled` | An operator or a client cancelled the job. |
| `attempt_failed` | Any other cause. The message shows the internal reason. |

The `job.failed` and `job.cancelled` events carry `error_code` and `error_message` in `data`.
The event message is cut to 255 bytes.

## Webhook redelivery

`POST /jobs/{id}/webhook-deliveries/{delivery_id}/redeliver` requeues a `failed` or `dead` delivery with the same signature material and `idempotency_key`.
A `delivered` delivery is refused with `409` and `code` `already_delivered`.
HTTP `503` with `code` `busy` means a lock conflict; retry the same request.
