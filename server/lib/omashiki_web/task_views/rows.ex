defmodule OmashikiWeb.TaskViews.Rows do
  @moduledoc """
  Read and format the task rows of a view.

  Reads only. Nothing here writes a job, an attempt, or the registry; a view
  decides which rows are shown and how, never how a job runs.
  """

  alias Omashiki.Jobs.Api
  alias OmashikiWeb.OperationHelpers, as: Ops
  alias OmashikiWeb.TaskViews.View

  @fields ~w(id status title instruction branch repository environment plugin sink priority
             attempt worker step submitted started finished wait duration result error
             correlation_id)
  @default_fields ~w(status title environment worker step duration)
  @context_segment ~r/^[A-Za-z0-9_-]+$/
  @text_limit 160
  @empty "—"

  def fields, do: @fields
  def default_fields, do: @default_fields

  @doc "True for a known field name or a `context.<path>` into the job payload context."
  def field?("context." <> path),
    do: path |> String.split(".") |> Enum.all?(&Regex.match?(@context_segment, &1))

  def field?(name) when is_binary(name), do: name in @fields
  def field?(_name), do: false

  def label("context." <> path), do: path
  def label("correlation_id"), do: "correlation"
  def label(field), do: field

  @doc "Read the rows of `view` for `user`, resolving relative time filters against `now`."
  def load(user, %View{} = view, %DateTime{} = now) do
    {:ok, %{entries: rows}} =
      Api.list(user,
        filter: resolve_filter(view.filter, now),
        sort: view.sort,
        page_size: view.limit,
        as: :rows
      )

    rows
  end

  @doc "Turn a view's relative filters into absolute ones at `now`."
  def resolve_filter(filter, %DateTime{} = now) do
    Map.new(filter, fn
      {:since, seconds} -> {:since, DateTime.add(now, -seconds, :second)}
      pair -> pair
    end)
  end

  @doc """
  Split rows into `{group, rows}` pairs. Status groups follow the lifecycle
  order and include empty statuses, so a board keeps stable columns.
  """
  def groups(rows, %View{group_by: nil}), do: [{nil, rows}]

  def groups(rows, %View{group_by: :status} = view) do
    by_status = Enum.group_by(rows, & &1.job.status)
    Enum.map(view_statuses(view), &{&1, Map.get(by_status, &1, [])})
  end

  def groups(rows, %View{group_by: key}) do
    rows
    |> Enum.group_by(&group_value(&1, key))
    |> Enum.sort_by(fn {group, _rows} -> group end)
  end

  @doc "Count rows by status, for the statuses the view can show."
  def status_counts(rows, %View{} = view) do
    counts = Enum.frequencies_by(rows, & &1.job.status)
    Enum.map(view_statuses(view), &{&1, Map.get(counts, &1, 0)})
  end

  defp view_statuses(%View{filter: filter}),
    do: filter |> Map.get(:status, Api.statuses()) |> Enum.uniq()

  def group_value(%{job: job}, :status), do: job.status
  def group_value(%{job: job}, :environment), do: job.environment
  def group_value(%{job: job}, :repository), do: job.repository || "no repository"
  def group_value(%{job: job}, :priority), do: "priority #{job.priority}"

  def group_value(%{attempt: attempt}, :worker),
    do: (attempt && attempt.machine_id) || "unassigned"

  def group_value(%{job: job}, :plugin),
    do: dig(job.admitted_environment, ["preset", "plugin"]) || "unknown"

  def group_value(%{job: job}, :sink), do: dig(job.admitted_environment, ["sink"]) || "unknown"

  @doc "Rendered `{text, class}` for `field` of `row`; `class` is nil for plain text."
  def cell(%{job: job}, "id", _now), do: plain(Ops.short_id(job.id))

  def cell(%{job: job}, "status", _now),
    do: {Ops.status_label(job.status), Ops.status_class(job.status)}

  def cell(row, "title", _now), do: plain(title(row))
  def cell(%{job: job}, "instruction", _now), do: plain(truncate(payload(job, "instruction")))
  def cell(row, "branch", _now), do: plain(branch(row))
  def cell(%{job: job}, "repository", _now), do: plain(job.repository)
  def cell(%{job: job}, "environment", _now), do: plain(job.environment)
  def cell(row, "plugin", _now), do: plain(group_value(row, :plugin))
  def cell(row, "sink", _now), do: plain(group_value(row, :sink))
  def cell(%{job: job}, "priority", _now), do: plain(Integer.to_string(job.priority))
  def cell(%{job: job}, "attempt", _now), do: plain(Integer.to_string(job.current_attempt))
  def cell(%{attempt: attempt}, "worker", _now), do: plain(attempt && attempt.machine_id)

  def cell(%{steps: steps}, "step", _now) do
    case current_step(steps) do
      nil -> plain(nil)
      step -> {step.key, Ops.status_class(step.status)}
    end
  end

  def cell(%{job: job}, "submitted", now), do: plain(ago(job.inserted_at, now))
  def cell(%{job: job}, "started", now), do: plain(ago(job.started_at, now))
  def cell(%{job: job}, "finished", now), do: plain(ago(job.finished_at, now))

  def cell(%{job: job}, "wait", now),
    do: plain(span(job.queued_at, job.started_at || job.finished_at || now))

  def cell(%{job: job}, "duration", now), do: plain(span(job.started_at, job.finished_at || now))
  def cell(row, "result", _now), do: plain(result(row))
  def cell(%{job: job}, "error", _now), do: error_cell(job.terminal_error)
  def cell(%{job: job}, "correlation_id", _now), do: plain(job.correlation_id)

  def cell(%{job: job}, "context." <> path, _now),
    do: plain(render_value(dig(payload_context(job), String.split(path, "."))))

  @doc "A short human title: payload title, branch, or the first instruction line."
  def title(%{job: job, attempt: attempt}) do
    payload(job, "title") || payload(job, "branch") ||
      dig(job.admitted_repository, ["task_branch"]) || (attempt && attempt.branch) ||
      first_line(payload(job, "instruction")) || Ops.short_id(job.id)
  end

  @doc "Elapsed time between two instants, or nil when the start is unknown."
  def span(nil, _to), do: nil

  def span(%DateTime{} = from, %DateTime{} = to),
    do: format_seconds(max(DateTime.diff(to, from, :second), 0))

  def format_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  def format_seconds(seconds) when seconds < 3_600,
    do: "#{div(seconds, 60)}m#{pad(rem(seconds, 60))}s"

  def format_seconds(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3_600)}h#{pad(div(rem(seconds, 3_600), 60))}m"

  def format_seconds(seconds),
    do: "#{div(seconds, 86_400)}d#{div(rem(seconds, 86_400), 3_600)}h"

  def payload(%{payload: %{} = payload}, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def payload(_job, _key), do: nil

  def payload_context(%{payload: %{"context" => %{} = context}}), do: context
  def payload_context(_job), do: nil

  defp branch(%{job: job, attempt: attempt}) do
    (attempt && attempt.branch) || payload(job, "branch") ||
      dig(job.admitted_repository, ["task_branch"])
  end

  defp current_step(steps) do
    Enum.find(steps, &(&1.status == "running")) ||
      steps |> Enum.reject(&(&1.status == "pending")) |> List.last()
  end

  defp result(%{job: job, attempt: attempt}) do
    cond do
      attempt && attempt.head_sha ->
        "#{attempt.branch || "commit"} @ #{String.slice(attempt.head_sha, 0, 7)}"

      digest = find_digest(job.terminal_result) ->
        "digest #{String.slice(digest, 0, 12)}"

      job.status == "succeeded" ->
        "completed"

      true ->
        nil
    end
  end

  # A files result nests its archive metadata; look one level down for it.
  defp find_digest(%{"digest" => digest}) when is_binary(digest), do: digest

  defp find_digest(%{} = result) do
    Enum.find_value(result, fn
      {_key, %{"digest" => digest}} when is_binary(digest) -> digest
      _ -> nil
    end)
  end

  defp find_digest(_result), do: nil

  defp error_cell(nil), do: plain(nil)

  defp error_cell(error) do
    text =
      case [dig(error, ["code"]), dig(error, ["message"])] |> Enum.reject(&is_nil/1) do
        [] -> render_value(error)
        parts -> parts |> Enum.map_join(": ", &to_string/1) |> truncate()
      end

    {text, "text-status-failed"}
  end

  defp plain(nil), do: {@empty, "text-on-surface-variant"}
  defp plain(""), do: {@empty, "text-on-surface-variant"}
  defp plain(text), do: {text, nil}

  defp ago(nil, _now), do: nil
  defp ago(%DateTime{} = at, now), do: "#{span(at, now)} ago"

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_value, _keys), do: nil

  defp render_value(nil), do: nil
  defp render_value(value) when is_binary(value), do: truncate(value)

  defp render_value(value) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp render_value(value), do: value |> Jason.encode!() |> truncate()

  defp first_line(nil), do: nil

  defp first_line(text) do
    case text |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      "" -> nil
      line -> truncate(line, 80)
    end
  end

  defp truncate(text, limit \\ @text_limit)
  defp truncate(nil, _limit), do: nil

  defp truncate(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit - 1) <> "…",
      else: text
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
