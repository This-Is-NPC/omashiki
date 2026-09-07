# How to cancel and retry a job

Use cancellation to stop waiting or active work.
Use retry to create another attempt for a failed or cancelled job.

## Before you start

Set `OMASHIKI_URL`, `OMASHIKI_API_TOKEN`, and `JOB_ID`.
Use the token that owns the job.
[Read the job](how-to-follow-and-retrieve-a-job.md) to check its ID and current status.

## Cancel a job

```bash
curl --fail-with-body -sS -X POST \
  -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/cancel"
```

The house records cancellation before it interrupts active execution.
Container cleanup can finish after the response.
Cancellation does not reverse external tool actions that already completed.

Read the job again to confirm its terminal status.
If it completed before cancellation, use the returned state as the result of the race.

## Retry a job

Correct the failure cause before you retry.
Then send:

```bash
curl --fail-with-body -sS -X POST \
  -H "Authorization: Bearer $OMASHIKI_API_TOKEN" \
  "$OMASHIKI_URL/api/v1/jobs/$JOB_ID/retry"
```

A retry keeps the job ID and creates the next numbered attempt.
A successful job cannot be retried.
The retry does not accept a replacement instruction or environment.
Submit a new job if the task or admitted configuration must change.

[Follow the job](how-to-follow-and-retrieve-a-job.md) to inspect the new attempt.
The [API reference](api.md) describes transition errors.
