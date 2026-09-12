# Public API reference

The public API uses the `/api/v1` prefix.
The live contract is `GET /api/v1/openapi.json`.
Do not keep a generated copy of that document in the repository.

Errors use `application/problem+json` (RFC 9457).
Each error body has `type`, `title`, `status`, `code`, `detail`, `errors`, and `request_id`.
The `code` values are the enum in the OpenAPI Problem schema.

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

Scopes are `read`, `submit`, and `cancel`.
Submit, retry, and webhook redeliver require `submit`.
Cancellation requires `cancel`.
Listing, inspection, events, and results require `read`.
A token that lacks a required scope receives `403` with `code` `insufficient_scope`.

`allowed_environments` is a non-empty list of environment names, or `["*"]` for every registered environment.
`max_active_jobs` is the number of non-terminal jobs that token may hold.

Local authentication-disabled mode does not remove the token requirement for job submission.
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

## Wait and listing

`GET /jobs/{id}/result?wait=60` holds the connection until the job is terminal or the wait expires, to a maximum of 60 seconds.
HTTP `202` with `retry-after` means the job is still running.
HTTP `409` with `code` `result_not_ready` means the caller did not supply `wait` and the job is not terminal.

A successful result includes `summary`, `changes` (`files_changed`, `insertions`, `deletions`, `files`), and `compare_url` when the remote is GitHub or GitLab.

`GET /jobs` pages with an opaque `cursor` and returns `next_cursor`.
The page size is 50.
Filter by `status`, `environment`, `repository`, `worker`, `correlation_id`, and `since`.
An unknown `status` value returns HTTP `422` with `code` `invalid_status`.

## Webhook redelivery

`POST /jobs/{id}/webhook-deliveries/{delivery_id}/redeliver` requeues a `failed` or `dead` delivery with the same signature material and `idempotency_key`.
A `delivered` delivery is refused with `409` and `code` `already_delivered`.
HTTP `503` with `code` `busy` means a lock conflict; retry the same request.
