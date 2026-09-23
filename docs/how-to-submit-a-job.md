# How to submit a job

This procedure submits one job through the public API.
The house returns a job ID after admission.

## Before you start

You need a running house, an API token, and an environment with working model access.
You also need `curl` and `jq` for these commands.
Follow [API authentication](api.md#authentication) if you do not have a token.

Set the house URL and read your token:

```bash
export OMASHIKI_URL=http://127.0.0.1:4010
read -rs -p 'Omashiki API token: ' OMASHIKI_API_TOKEN
export OMASHIKI_API_TOKEN
```

## 1. Choose the environment

List the registered environments and their sinks:

```bash
curl --fail-with-body -sS -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/environments" | jq '.data[] | {name, sink}'
```

The sink decides the shape of the request:

| Sink | Result | `repo` |
| --- | --- | --- |
| `files` | A file archive. | Not allowed: `422 repository_not_allowed`. |
| `none` | Completion metadata. | Not allowed: `422 repository_not_allowed`. |
| `git` | A committed task branch in a registered repository. | Required: without it, `422 repository_required`. |

For a `git` environment, list the registered repositories:

```bash
curl --fail-with-body -sS -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/repositories" | jq '.data'
```

Use names from those responses.

## 2. Write the request

The payload accepts `instruction`, `context`, `title`, and `branch`.
`instruction` is required.
The board shows `title` as the name of the job.
It does not accept provider, model, harness, or authentication controls.
Use a new idempotency key for each new task.
Keep the same key when you repeat a request after a connection failure.
The correlation ID connects the job to your ticket or maintenance operation.

### Files or none environment

This example uses the `opencode` environment from `deploy/omashiki.toml`, which has the `files` sink:

```bash
cat > /tmp/omashiki-job.json <<'JSON'
{
  "idempotency_key": "release-checklist-001",
  "correlation_id": "maintenance:release-checklist",
  "environment": "opencode",
  "priority": 1,
  "payload": {
    "instruction": "Write a one-page release checklist in English. Save it as release-checklist.md.",
    "title": "release-checklist",
    "context": {"reason": "Operators cut a release every month."}
  }
}
JSON
```

### Git environment

This example uses the `omashiki` repository and the `opencode` environment from `examples/single-node.omashiki.toml`, which has the `git` sink:

```bash
cat > /tmp/omashiki-job.json <<'JSON'
{
  "idempotency_key": "readme-health-check-001",
  "correlation_id": "maintenance:readme-health-check",
  "repo": "omashiki",
  "environment": "opencode",
  "priority": 1,
  "payload": {
    "instruction": "Add a health-check example to README.md. Check the endpoint in the source. Write the example in English. Commit the change.",
    "title": "readme-health-check",
    "context": {"reason": "Operators need to check service access."}
  }
}
JSON
```

A `git` job requires `title` or `branch` to name its task branch.
`branch` is used as given.
`title` becomes a lowercase, hyphenated branch name and cannot contain `/`.

## 3. Submit the request

```bash
curl --fail-with-body -sS \
  -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/omashiki-job.json \
  "$OMASHIKI_URL/api/v1/jobs" > /tmp/omashiki-admission.json
JOB_ID=$(jq -er '.data.id' /tmp/omashiki-admission.json)
export JOB_ID
```

HTTP `202` means that the house accepted the job.
It does not mean that the job succeeded.
Keep the job ID to [follow execution and retrieve the result](how-to-follow-and-retrieve-a-job.md).

## If admission fails

| Response | Action |
| --- | --- |
| `401` | Supply a valid API token. Local job submission also requires a token. |
| `422` | Read the field error. Check registered names and request values. |
| `429 capacity_exhausted` | Wait before another submission. The request was not admitted. |
| `503 admission_paused` | Wait for the configuration reload to finish. |
| `503 busy` | Retry the same request. A lock conflict left the job unchanged. |

An admitted job can wait in the queue without an admission error.
See [the API reference](api.md) for batches and dependencies.
