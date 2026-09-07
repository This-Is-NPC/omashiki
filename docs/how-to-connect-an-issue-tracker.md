# How to connect an issue tracker

Use a handler to convert tracker events into Omashiki requests.
The handler also receives terminal notifications from the house.

## Before you start

Complete [one manual submission](how-to-submit-a-job.md).
You need a working repository, environment, and API token.
The tracker must reach the handler's webhook URL.
The house must reach the handler's terminal notification URL.

## 1. Configure the reference handler

The [GitHub handler](../examples/handler/github_issue_handler.py) uses the Python standard library.
It accepts `issues.labeled` events with a configured label.
Other events do not create jobs.

```bash
export OMASHIKI_URL=http://127.0.0.1:4010
export OMASHIKI_TOKEN="$OMASHIKI_API_TOKEN"
export OMASHIKI_REPO=my-service
export OMASHIKI_ENVIRONMENT=opencode
export HANDLER_LABEL=omashiki
export HANDLER_PORT=8090
read -rs -p 'GitHub webhook secret: ' GITHUB_WEBHOOK_SECRET
export GITHUB_WEBHOOK_SECRET
read -rs -p 'Terminal webhook secret: ' OMASHIKI_WEBHOOK_SECRET
export OMASHIKI_WEBHOOK_SECRET
python3 examples/handler/github_issue_handler.py
```

Replace the repository and environment names with names from your house.
Configure GitHub to send issue events to the handler's reachable `/github` URL.
Use the same GitHub webhook secret on both sides.

## 2. Submit one issue

Add the configured label to an issue with a small task.
The handler verifies the signature before it submits work.
It builds the instruction from the issue title and body.
It includes the issue metadata in `context`.

The idempotency key identifies the repository, issue, and label.
Repeated event delivery selects the same job.
The correlation ID identifies the source issue.
Follow the returned job ID through the [job API](how-to-follow-and-retrieve-a-job.md).

## 3. Configure the return path

Ask the house operator to configure the submitting token's terminal webhook destination and secret.
The destination must use the handler's reachable `/omashiki` URL.
The secret must match `OMASHIKI_WEBHOOK_SECRET`.
Setting that variable in the handler does not configure the house.

The public API has no webhook-configuration route.
The [internal integration entry point](internal/architecture.md#terminal-notifications) describes the available server function.

The handler verifies the terminal signature before it calls `on_terminal`.
That callback currently logs the status and branch.
Add your own callback code to comment on the issue or open a pull request.
Use the handler's credentials for that action.
Make the callback tolerate repeated event delivery.

## Other trackers

For Jira, map a workflow transition to an instruction and acceptance criteria.
For Azure DevOps, map a work item to the same envelope.
For ServiceNow, map an incident to a bounded investigation task.
You must supply each system's authentication, event mapping, and result callback.
Omashiki does not include these connectors.

## If the integration fails

Check `/github` with the GitHub secret.
Check `/omashiki` with the submitting token's webhook secret.
Inspect `/api/v1/jobs/<id>/webhook-deliveries` for delivery status.

An [agent identity](how-to-configure-an-agent-identity.md) serves a different purpose.
It lets the running agent act as a GitHub App through the house.
