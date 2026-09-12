---
name: omashiki
description: "Operate an existing Omashiki installation through its HTTP API. Use when the user asks to submit, inspect, follow, cancel, retry, or retrieve coding-agent jobs managed by Omashiki. Also use to discover registered repositories and execution environments."
---

# Omashiki

Omashiki is a durable queue for governed coding-agent jobs. Operate the user's
existing installation through its public HTTP API. Do not edit the Omashiki
server configuration or start, stop, upgrade, or reinstall the server unless the
user explicitly asks for administration work.

The contract is the OpenAPI document the server publishes. Do not invent routes,
fields, or error codes. Fetch the specification and follow it.

## Connection

Use these environment variables:

- `OMASHIKI_URL`: server base URL without a trailing slash. If it is unset, ask
  the user for the URL. The common local default is `http://127.0.0.1:4010`.
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
  "{{OMASHIKI_URL}}/api/v1/health"
```

The expected response is `{"status":"ok"}`. Report connection failures as
connection failures; do not infer that the queue or a job failed.

Fetch the live contract:

```bash
curl --fail-with-body --silent --show-error \
  "{{OMASHIKI_URL}}/api/v1/openapi.json"
```

For authenticated requests, use the bearer header:

```bash
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "{{OMASHIKI_URL}}/api/v1/repositories"
```

Install or refresh this skill from the same server:

```bash
mkdir -p "${HOME:?}/.agents/skills/omashiki"
curl --fail-with-body --silent --show-error \
  "{{OMASHIKI_URL}}/api/v1/agent-skill" \
  > "${HOME:?}/.agents/skills/omashiki/SKILL.md"
```

## Discover Before Submitting

Never guess repository or environment names. Read the discovery operations in
the OpenAPI document and fetch both registries. Select only registered names. If
multiple choices fit and the user did not select one, ask rather than guessing.

The environment determines the harness, provider configuration, credentials,
network, mounts, resources, and model policy. A caller cannot override those
controls in a job.

## Submit And Follow Jobs

Confirm that the instruction is concrete and contains enough acceptance criteria
for an autonomous coding agent. Put optional structured, non-secret supporting
data in `payload.context`.

Build request bodies with a JSON encoder such as `jq -n`. Do not interpolate
arbitrary task text into a hand-written JSON string. Follow the request schema
in `openapi.json` for `POST /api/v1/jobs` and `POST /api/v1/jobs/batch`.

Rules that the schema does not restate:

- Reuse `idempotency_key` only when retrying an HTTP request whose outcome is
  unknown. Do not reuse it for different work.
- Do not include `harness`, `provider`, `model`, or `auth` in the payload.
- Do not place passwords, tokens, private keys, or provider credentials in the
  instruction or context.
- Capture `data.id` from a successful admission. Do not predict a job ID.

Token scopes are `read`, `submit`, and `cancel`. Submit, retry, and webhook
redeliver require `submit`. Cancellation requires `cancel`. Listing, inspection,
events, and results require `read`.

## Wait For Results

Prefer `GET /api/v1/jobs/{id}/result?wait=60` over a local poll loop. The server
holds the connection until the job is terminal or the wait expires. HTTP `202`
with `retry-after` means the job is still running; wait again. HTTP `409` with
`code` `result_not_ready` means no `wait` was supplied and the job is not
terminal.

A successful result includes status, attempt, Git identity when the sink is
git, `summary`, `changes`, and `compare_url` when the remote is recognised.
Report the branch and commit identifiers exactly as returned. Do not claim that
changes were merged.

## Cancel, Retry, And Errors

Cancellation is a mutation. Perform it only when the user requested it or has
confirmed the specific job. Retry is allowed only for `failed` or `cancelled`
jobs.

Errors use `application/problem+json` (RFC 9457). Preserve HTTP status, `code`,
`detail`, `errors`, and `request_id`. Do not work around authorization, ownership,
admission, or environment policy errors.

Common codes: `missing_token`, `token_expired`, `invalid_token`,
`insufficient_scope`, `forbidden`, `not_found`, `result_not_ready`,
`environment_not_allowed`, `max_active_jobs`, `capacity_exhausted`,
`unknown_repository`, `unknown_environment`, `invalid_request`.

## Report Back

After a mutation, report the job ID, current status, repository, environment,
and attempt. After completion, report the terminal status and either the exact
result branch, head SHA, and change summary, or the returned failure.
