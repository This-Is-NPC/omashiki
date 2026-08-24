---
name: omashiki
description: "Operate an existing Omashiki installation through its HTTP API. Use when the user asks to submit, inspect, follow, cancel, retry, or retrieve coding-agent jobs managed by Omashiki. Also use to discover registered repositories and execution environments."
---

# Omashiki

Omashiki is a durable queue for governed coding-agent jobs. Operate the user's
existing installation through its public HTTP API. Do not edit the Omashiki
server configuration or start, stop, upgrade, or reinstall the server unless the
user explicitly asks for administration work.

## Connection

Use these environment variables:

- `OMASHIKI_URL`: server base URL without a trailing slash. If it is unset, ask
  the user for the URL and mention `http://127.0.0.1:4010` only as the common
  local default.
- `OMASHIKI_API_TOKEN`: bearer token used for discovery and job operations.

Never ask the user to paste a password or API token into chat. Never print the
token, put it in a URL query string, enable shell tracing around it, or embed its
literal value in a command. Refer to it only as `$OMASHIKI_API_TOKEN`. If it is
missing, stop before authenticated operations and ask the user to expose it to
the agent process. Account signup and token issuance are human bootstrap steps,
not operations to perform autonomously.

Check availability before doing other work:

```bash
curl --fail-with-body --silent --show-error \
  "$OMASHIKI_URL/api/v1/health"
```

The expected response is `{"status":"ok"}`. Report connection failures as
connection failures; do not infer that the queue or a job failed.

For authenticated requests, use the bearer header:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/repositories"
```

## Discover Before Submitting

Never guess repository or environment names. Fetch both registries:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/repositories"

curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/environments"
```

Repository entries expose `name` and `base_branch`. Environment entries expose
safe public metadata such as `name`, `harness`, `runtime`, timeout, network,
capabilities, and resources. Select only registered names. If multiple choices
fit and the user did not select one, ask rather than guessing.

The environment determines the harness, provider configuration, credentials,
network, mounts, resources, and model policy. A caller cannot override those
controls in a job.

## Submit A Job

Confirm that the instruction is concrete and contains enough acceptance criteria
for an autonomous coding agent. Put optional structured, non-secret supporting
data in `payload.context`.

Submit this JSON shape to `POST /api/v1/jobs`:

```json
{
  "schema_version": 1,
  "idempotency_key": "a-stable-unique-request-id",
  "correlation_id": "a-logical-workflow-id",
  "repo": "registered-repository-name",
  "environment": "registered-environment-name",
  "payload": {
    "instruction": "The complete task for the coding agent.",
    "context": {
      "ticket": "optional-reference"
    }
  },
  "priority": 1
}
```

Rules:

- `schema_version` must be `1`.
- `idempotency_key` must be non-empty and unique to the intended submission.
  Reuse the same key when retrying an HTTP request whose outcome is unknown. Do
  not reuse it for different work.
- `correlation_id` groups related work and must be non-empty.
- `payload.instruction` is required and must not be blank.
- `payload.context` is optional, but when present it must be a JSON object.
- `priority` is an integer from `0` through `3`; lower values run first. Use `1`
  unless the user or surrounding workflow requires another priority.
- Do not include `harness`, `provider`, `model`, or `auth` in the payload. They
  are forbidden control fields.
- Do not place passwords, tokens, private keys, or provider credentials in the
  instruction or context.

Build JSON with a real JSON encoder such as `jq -n` or a language standard
library. Do not interpolate arbitrary task text into a hand-written JSON string.
Then submit it:

```bash
curl --fail-with-body --silent --show-error \
  --request POST \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data-binary @request.json \
  "$OMASHIKI_URL/api/v1/jobs"
```

A successful admission returns HTTP `202` with the job under `data`. Capture
`data.id` exactly from the response. Do not predict a job ID. The initial status
is normally `queued`, or `blocked` for a child waiting on a parent.

Avoid leaving request files containing sensitive business context behind. Use a
secure temporary file and remove it after submission when the request cannot be
sent directly from the JSON encoder.

## Inspect And Follow Jobs

List jobs owned by the current token:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs?limit=50"
```

The optional `status` filter accepts `blocked`, `queued`, `provisioning`,
`running`, `succeeded`, `failed`, or `cancelled`. `limit` must be from 1 to 100.

Inspect one job:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID"
```

For durable event history:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/events/history"
```

For live server-sent events:

```bash
curl --no-buffer --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  --header "Accept: text/event-stream" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/events"
```

Reconnect with the last received event ID in the `Last-Event-ID` header when a
stream is interrupted. Never pass the bearer token as a query parameter.

Terminal statuses are `succeeded`, `failed`, and `cancelled`. When polling rather
than streaming, use a modest delay and stop at a user-appropriate deadline. Do
not busy-loop and do not describe a non-terminal job as failed merely because a
local wait timed out.

## Retrieve Results

Only request a result after the job reaches a terminal status:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/result"
```

HTTP `409` with `result_not_ready` means the job is still non-terminal. A
successful response includes status, attempt number, branch, base and head SHAs,
worktree cleanliness, result data, error data, and finish time. Report the branch
and commit identifiers exactly as returned. Do not claim that changes were
merged; Omashiki returns a result branch.

## Cancel And Retry

Cancellation is a mutation. Perform it only when the user requested it or has
confirmed the specific job:

```bash
curl --fail-with-body --silent --show-error \
  --request POST \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/cancel"
```

Cancellation is idempotent. Retry is allowed only for `failed` or `cancelled`
jobs and creates a new attempt on the same job:

```bash
curl --fail-with-body --silent --show-error \
  --request POST \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/retry"
```

Retry returns HTTP `202`. Do not retry automatically without understanding the
failure and obtaining user approval when retrying could consume meaningful time,
provider quota, or money.

## Handle Errors Precisely

Preserve the HTTP status and the server's error `code`, `message`, and `details`
when reporting failures. Common meanings:

- `401 missing_token` or `token_required`: authentication is absent.
- `403 invalid_token`: the token is invalid.
- `403 forbidden`: the job belongs to another token.
- `404 not_found`: the job does not exist or is unavailable.
- `409 idempotency_conflict`: the idempotency key belongs to another token.
- `409 result_not_ready`: wait for a terminal status.
- `422 unknown_repository` or `unknown_environment`: repeat discovery and use a
  registered name.
- `422 invalid_request`: fix the fields identified in `details`; do not silently
  drop user intent.
- `429 capacity_exhausted`: report saturation and wait or ask before retrying.

Do not work around authorization, ownership, admission, or environment policy
errors. Explain what the server rejected and ask for the minimum decision needed
to continue.

## Report Back

After a mutation, report the job ID, current status, repository, environment,
and attempt. After completion, report the terminal status and either the exact
result branch and head SHA or the returned failure. Keep operational output
concise, but never hide a partial submission, timeout, cancellation, or retry.
