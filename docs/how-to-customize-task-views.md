# Customize task views

The Home screen shows the tasks that the house admits and the processing state of each task.
A views file selects the tasks, fields, grouping, and layout for this screen.
The views file changes only the screen. It cannot change a job, the queue, or the registry.

## Prerequisites

- A running house. See [install and stop Omashiki](how-to-install-and-stop.md).
- Write access to the home directory of the user that runs the house.

## Create a views file

1. Copy the [example views file](../examples/ui.toml) to `~/.config/omashiki/ui.toml`.
2. Edit the views with the keys in this page.
3. Open the Home screen at `/` in the browser.

Result: the header shows `Views from` and the file path.
The screen reads the file again every 2 seconds. A page reload is not necessary.

If the screen shows `Views file rejected`, read the listed problems.
Correct the file and save it.
The screen keeps the last valid views until the file is correct.

## File location

The house uses the first path that applies:

| Order | Path |
| --- | --- |
| 1 | The `OMASHIKI_UI_CONFIG` environment variable. |
| 2 | `$XDG_CONFIG_HOME/omashiki/ui.toml`. |
| 3 | `~/.config/omashiki/ui.toml`. |

The file must be on the machine that runs the house.
If the file does not exist, the screen shows the built-in views.

## File structure

One file contains all views of the house.
Each `[[views]]` table declares one view.
The screen shows one tab for each view, in file order.

```toml
default_view = "active"

[[views]]
name = "active"
title = "In progress"
filter = { status = ["queued", "running"] }
fields = ["status", "title", "worker", "duration"]

[[views]]
name = "failures"
title = "Failures today"
filter = { status = ["failed"], since = "24h" }
fields = ["title", "error", "context.issue_url"]
```

| Key | Required | Value |
| --- | --- | --- |
| `default_view` | No | The `name` of the view that opens first. The default is the first view. |
| `views` | Yes | One or more `[[views]]` tables. |

## View keys

| Key | Default | Value |
| --- | --- | --- |
| `name` | Required | Unique URL name. Use `a-z`, `0-9`, `_`, and `-`, with a maximum of 40 characters. |
| `title` | The `name` value | Tab and header text, with a maximum of 60 characters. |
| `layout` | `"list"` | `"list"` shows a table. `"board"` shows one column for each group. `"graph"` shows the fleet graph. |
| `fields` | `status`, `title`, `environment`, `worker`, `step`, `duration` | Fields in display order. |
| `filter` | No filter | Table of filter keys. A task must match all keys. |
| `sort` | `"-submitted"` | `submitted`, `started`, `finished`, or `priority`. Add the `-` prefix for descending order. |
| `group_by` | None for a list, `status` for a board | `status`, `environment`, `repository`, `plugin`, `sink`, `priority`, or `worker`. |
| `limit` | `100` | Maximum number of tasks, from 1 through 500. |
| `blocks` | None | Summary blocks above the tasks: `status_counts`, `slots`, and `workers`. |
| `show_idle_workers` | `true` | Graph only. `false` hides nodes without a visible container. |
| `show_stale_workers` | `true` | Graph only. `false` hides workers that stopped polling. |

An unknown key rejects the file.
No key starts an action, such as cancel or retry.

## Filter keys

| Key | Value | Match |
| --- | --- | --- |
| `status` | A status or a list of statuses. | The job status. |
| `environment` | A name or a list of names. | The environment name. |
| `repository` | A name or a list of names. | The repository name. |
| `priority` | An integer from 0 through 3, or a list of integers. | The job priority. |
| `worker` | A machine ID or a list of machine IDs. | The machine of the current attempt. |
| `since` | A duration, such as `"30m"`, `"24h"`, or `"7d"`. | Jobs admitted within this duration. |

The statuses are `blocked`, `queued`, `provisioning`, `running`, `succeeded`, `failed`, and `cancelled`.

## Fields

| Field | Content |
| --- | --- |
| `id` | The first 8 characters of the job ID. |
| `status` | The job status. |
| `title` | The payload `title`, the branch, or the first instruction line. |
| `instruction` | The payload instruction, with a maximum of 160 characters. |
| `branch` | The task branch of the current attempt or the request. |
| `repository` | The repository name. |
| `environment` | The environment name. |
| `plugin` | The plugin of the admitted environment. |
| `sink` | The result sink: `git`, `files`, or `none`. |
| `priority` | The job priority. |
| `attempt` | The current attempt number. |
| `worker` | The machine ID of the current attempt. |
| `step` | The running step, or the last started step. |
| `submitted` | The time since admission. |
| `started` | The time since the job started. |
| `finished` | The time since the job finished. |
| `wait` | The time from queue entry to start. |
| `duration` | The time from start to finish, or from start to now. |
| `result` | The branch and commit, the file digest, or `completed`. |
| `error` | The terminal error code and message. |
| `correlation_id` | The correlation ID of the request. |
| `context.<path>` | The value at `<path>` in the payload `context`. Use `.` between nested keys. |

For example, `context.issue_url` shows the `issue_url` value of the payload `context`.

## Fleet graph

A view with `layout = "graph"` shows the house, each node that runs its jobs, and the containers on each node.
A node is a worker that polls this house, or this node when it runs jobs itself.
Each node shows its liveness, the time since its last report, and its used slots.
Each container shows its state, its age, and the view `fields` of its job.

The graph changes when a container is created, started, or removed.
A worker reports its containers within one second of a change.
A census every ten seconds corrects the reported list.
A worker becomes stale after thirty seconds without a poll or report.

The graph shows a container without job details when the job belongs to another operator.
With a job filter such as `status` or `environment`, the graph shows only containers of matching jobs.
The `worker` filter selects nodes by machine ID.
The graph does not use `group_by`.

## Task details

Select a task to open its details.
The details show the instruction, context, steps, events, result, and webhook deliveries.
The URL contains the view name and the job ID.
Press Escape or select `Close` to close the details.

The Home screen has no job actions.
Use the [public API](api.md) to cancel or retry a job.

## Limits

The screen shows only the jobs of the signed-in operator.
The screen shows only data that the house records.
For a `none` sink, check the external system to verify an external change.
