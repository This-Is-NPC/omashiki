# How to share workers between houses

Use this procedure when several developers need the same execution machines.
Each house retains its own database, registry, credentials, and results.

## Before you start

Complete [worker setup](how-to-add-a-worker.md) for one house.
Prepare a separate manager configuration and worker token for each additional house.
Use a unique manager ID for each house on the worker.

## 1. Start separate managers

The manager Compose file supports separate project names and configuration paths.
For example, with the corresponding secrets already available in the shell:

```bash
MANAGER_PORT=4010 OMASHIKI_CONFIG_HOST=/srv/ana/omashiki.toml \
  OMASHIKI_WORKER_TOKEN="$ANA_TOKEN" \
  docker compose -p ana -f examples/compose.manager.yml up -d

MANAGER_PORT=4020 OMASHIKI_CONFIG_HOST=/srv/joao/omashiki.toml \
  OMASHIKI_WORKER_TOKEN="$JOAO_TOKEN" \
  docker compose -p joao -f examples/compose.manager.yml up -d
```

Replace paths, ports, and token variables with your deployment values.
Each Compose project creates its own database volume.
For separate host processes, also configure distinct supply-chain socket paths.

## 2. Enroll the worker into each house

Set the worker listener URL and enrollment secret in `.env`.
Then enroll each manager:

```bash
mise run worker:enroll -- --manager-id ana \
  --manager-url http://ana.lan:4010 --worker-token "$ANA_TOKEN"
mise run worker:enroll -- --manager-id joao \
  --manager-url http://joao.lan:4020 --worker-token "$JOAO_TOKEN"
```

The worker must reach both URLs from its process and job containers.
Enrollment with an existing manager ID replaces that entry.

## 3. Check both houses

Submit one job to each house with that house's API token.
Read each result through the house that accepted the job.
The worker shares one local slot limit across all enrolled houses.
A limit of four means four concurrent jobs in total.

The worker stores mirrors and execution state separately for each house.
An unavailable house does not remove the other enrollments.

## Remove one enrollment

Use the worker listener with its enrollment secret:

```bash
curl --fail-with-body -X DELETE \
  -H "Authorization: Bearer $OMASHIKI_ENROLL_SECRET" \
  "$OMASHIKI_WORKER_URL/internal/enroll/ana"
```

Replace `ana` with the manager ID to remove.
This operation removes that enrollment. It does not remove other houses.
Use the house job API to cancel its active work when required.
