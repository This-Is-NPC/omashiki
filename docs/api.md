# Public API reference

The public API uses the `/api/v1` prefix.
The [OpenAPI file](api/jobs-openapi.json) describes request and response schemas.

## Authentication

Use an existing operator account to request a token.
Write the credentials to a private temporary file:

```bash
export OMASHIKI_URL=http://127.0.0.1:4010
umask 077
cat > /tmp/omashiki-login.json <<'JSON'
{
  "username": "replace-with-your-username",
  "password": "replace-with-your-password",
  "name": "local-client"
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

For a house without an operator, `/sessions/signup` accepts `email`, `username`, `password`, and optional token `name`.
It returns HTTP `201` with the first token.
Signup returns `409` after an operator exists.
Token issuance returns `200`, invalid credentials return `401`, and rate limiting returns `429`.

Local authentication-disabled mode does not remove the token requirement for job submission.
Use the submitting token for job inspection and result access.

## Routes

| Method | Path after `/api/v1` | Purpose |
| --- | --- | --- |
| GET | `/health` | Public service health. |
| POST | `/sessions/signup` | Create the first operator and token. |
| POST | `/sessions/issue_token` | Exchange account credentials for a token. |
| GET | `/repositories` | List safe repository metadata. |
| GET | `/environments` | List safe environment metadata. |
| GET | `/fleet` | Read the nodes that run jobs and their containers. |
| POST | `/jobs` | Admit one job. |
| POST | `/jobs/batch` | Admit an atomic batch. |
| GET | `/jobs` | List accessible jobs. |
| GET | `/jobs/{id}` | Read one job. |
| GET | `/jobs/{id}/result` | Read a terminal result. |
| POST | `/jobs/{id}/cancel` | Cancel waiting or active work. |
| POST | `/jobs/{id}/retry` | Retry failed or cancelled work. |
| GET | `/jobs/{id}/events/history` | Read retained events. |
| GET | `/jobs/{id}/events` | Stream events as SSE. |
| GET | `/jobs/{id}/events/stream` | Compatibility alias for SSE. |
| GET | `/jobs/{id}/webhook-deliveries` | Read redacted delivery status. |

## Fleet

`GET /fleet` returns one entry for each node that runs jobs for this house.
Each entry contains `machine_id`, `kind`, `stale`, `last_seen_at`, `capacity`, `free_slots`, and `containers`.
Each container contains `id`, `state`, `created_at`, `started_at`, and `job_id`.
`job_id` is `null` when the caller cannot read that job.
The route is read-only. It does not change a job, a lease, or capacity.

## Single job envelope

Required fields are `schema_version`, `idempotency_key`, `correlation_id`, `environment`, `payload`, and `priority`.
Set `schema_version` to `1`.
Set `priority` to an integer from `0` through `3`.
Include `repo` for a Git environment.
The `files` and `none` sinks do not require `repo`.

The payload supports these fields:

| Field | Rule |
| --- | --- |
| `instruction` | Required nonblank UTF-8 string. |
| `context` | Optional JSON object. |
| `title` | Optional task title. Git jobs require this field or `branch`. |
| `branch` | Optional valid Git branch name. Takes precedence over `title`. |

The encoded payload limit is 1 MiB per job.
Unknown fields and caller-supplied execution controls are refused.
See [submit a job](how-to-submit-a-job.md) for a complete request.

Admission returns HTTP `202` with `data.id` and the job state.
Repeating the same submitting token and idempotency key returns the existing job.
A key owned by another token produces a conflict.

## Batches and dependencies

A batch contains `schema_version`, `correlation_id`, and a `jobs` array.
The maximum is 100 jobs. The house admits all items or none.
Each item has a unique `ref` and the single-job fields except the batch-level fields.

`depends_on` is an array of dependency objects.
An object selects an existing job with `id`, or a same-batch job with `ref`.
Its optional `on_failure` value is `cancel`, `block`, or `proceed`.
The default is `cancel`.
Dependencies must have the same owner. Self-dependencies and cycles are refused.

```json
{
  "depends_on": [
    {"ref": "prepare", "on_failure": "block"}
  ]
}
```

This fragment belongs inside a batch job item.
The dependent job waits until its dependency conditions permit execution.
A request can also select a Git `base`.
See [the internal lifecycle](internal/job-lifecycle.md) for dependency artifact handling.

## Results and events

Terminal statuses are `succeeded`, `failed`, and `cancelled`.
A retry keeps the job ID and increments its attempt number.
Success is terminal and cannot be retried.

The result response wraps metadata in `data`.
Its `result` value depends on the sink.
Git fields can be null for non-Git results.
The public API does not expose a file archive download route.

SSE supports `Last-Event-ID` for reconnection.
Event history is bounded by retention.
A missing retained sequence produces an error instead of fabricated events.

## Terminal notifications

Webhook configuration belongs to the submitting API token.
It is not part of the job envelope.
The house signs terminal notifications with timestamp-bound HMAC-SHA256 over canonical JSON.
The delivery system can send the same event more than once.
Deduplicate by `event_id`.

The reference handler checks signatures and timestamps.
Use [tracker integration](how-to-connect-an-issue-tracker.md) to configure both directions.

## Error responses

Job API errors contain `error.code`, `error.message`, and `error.details`.
Authentication endpoints can use simpler error bodies.

| Status | Meaning |
| --- | --- |
| `401` | Authentication is missing or invalid. |
| `403` or `404` | The caller cannot access the requested resource. |
| `409` | State conflict, idempotency conflict, or result not ready. |
| `422` | Invalid request or unknown registry declaration. |
| `429` | Admission capacity or request rate limit. |
| `503` | Admission is paused during a draining reload. |

## Internal endpoints

Worker, gateway, and tool-proxy endpoints are not public client API.
They use worker credentials or temporary job claims.
An operator API token does not replace those credentials.
