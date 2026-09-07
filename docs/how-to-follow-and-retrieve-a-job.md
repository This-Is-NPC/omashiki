# How to follow a job and retrieve its result

Use this procedure after the house accepts a job.
You need its ID and the same API token used for submission.

Set `OMASHIKI_URL`, `OMASHIKI_API_TOKEN`, and `JOB_ID` in your shell.
The [submission procedure](how-to-submit-a-job.md) sets these variables.

## 1. Read the status

```bash
curl --fail-with-body -sS -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID" | jq '.data'
```

A waiting job can have status `blocked` or `queued`.
An active job can have status `provisioning` or `running`.
Terminal statuses are `succeeded`, `failed`, and `cancelled`.

## 2. Follow the events

```bash
curl --fail-with-body -N -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/events"
```

The response is a Server-Sent Events stream.
Press `Ctrl+C` to stop listening. This action does not cancel the job.
To reconnect, send the last received event ID in the `Last-Event-ID` header.

For retained event history, use:

```bash
curl --fail-with-body -sS -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/events/history" | jq '.data'
```

## 3. Retrieve the terminal result

```bash
curl --fail-with-body -sS -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/result" | jq '.data'
```

HTTP `409 result_not_ready` means that execution has not reached a terminal state.
Poll the status again before you request the result.

| Sink | Result |
| --- | --- |
| `git` | Branch, base SHA, head SHA, and clean-worktree status. |
| `files` | File archive metadata, including its digest and stored location. |
| `none` | Completion metadata, including `sink`, `job_id`, and `changed_bytes`. |

For Git output, review the branch before you merge it.
With a canonical remote, fetch the returned branch from that remote.
A local-only result remains on the execution machine.

The public API returns metadata for a file archive.
It does not provide an archive-download endpoint.
Ask the house operator to retrieve the archive from manager storage.
Do not assume that a manager storage path is readable from the client.

A failed job has an error record. Keep its code and details for diagnosis.
Use [cancel and retry](how-to-cancel-and-retry-a-job.md) when another attempt is appropriate.
