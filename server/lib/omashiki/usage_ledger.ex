defmodule Omashiki.UsageLedger do
  @moduledoc """
  Financial projection of LLM usage. Append-only; never updated.

  Distinct from `events`: same causal story, stricter schema and a
  `UNIQUE(request_id)` so retries cannot double-bill. Not a database view.

  Phase 4: when traffic goes through `Omashiki.Gateway`, the gateway
  records ledger rows from the **provider adapter** response (field truth).
  `cached_input_tokens` / `cache_write_tokens` / `reasoning_tokens` are
  **nullable**: `nil` means the adapter could not see the field (unknown),
  `0` means reported zero. Never coerce absence to `0` — that was fiction
  banned in Fase 0.
  `ExecutionDriver` skips `record_from_turn/3` for gateway turns
  (`usage_source: :gateway`), which is set from provision-time
  `llm_egress` (credential delivered as a gateway token). Direct provider
  keys in the sandbox keep `usage_source: :engine` and meter from the
  engine turn.
  """

  require Logger

  alias Omashiki.Repo
  alias Omashiki.UsageLedger.Entry

  @doc """
  Inserts a ledger row and fails softly when accounting is unavailable.

  Duplicate `request_id` is treated as success (idempotent retry).
  """
  def record(attrs) when is_map(attrs) do
    try do
      %Entry{}
      |> Entry.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, entry} ->
          {:ok, entry}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if unique_request_id_error?(errors) do
            {:ok, :already_recorded}
          else
            Logger.warning("[UsageLedger] record failed: #{inspect(changeset.errors)}")
            {:error, changeset}
          end
      end
    rescue
      error ->
        Logger.warning("[UsageLedger] record crashed: #{Exception.message(error)}")
        {:error, error}
    catch
      kind, reason ->
        Logger.warning("[UsageLedger] record threw #{kind}: #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  @doc """
  Records usage from an engine `turn_result` after the execution row was
  updated. `request_id` is `execution.id` + `:` + turn.

  Cache columns pass through as-is (`nil` when the engine did not report).
  """
  def record_from_turn(execution, turn, turn_result)
      when is_integer(turn) and is_map(turn_result) do
    record(%{
      request_id: "#{execution.id}:#{turn}",
      job_id: execution.job_id,
      attempt_id: execution.attempt_id,
      source: "engine",
      turn: turn,
      provider: turn_result[:provider] || execution.provider,
      model: turn_result[:model_resolved] || execution.model_resolved || execution.model,
      input_tokens: turn_result[:input_tokens] || 0,
      cached_input_tokens: Map.get(turn_result, :cached_input_tokens),
      output_tokens: turn_result[:output_tokens] || 0,
      reasoning_tokens: Map.get(turn_result, :reasoning_tokens),
      cache_write_tokens: Map.get(turn_result, :cache_write_tokens),
      provider_request_id: turn_result[:provider_request_id],
      occurred_at: DateTime.utc_now(:microsecond)
    })
  end

  @doc """
  Fallback when only the execution row is available (no turn_result).
  Cache/reasoning columns stay `nil` (unknown — execution has no those fields).
  """
  def record_from_execution(execution, turn \\ 1) when is_integer(turn) do
    record(%{
      request_id: "#{execution.id}:#{turn}",
      job_id: execution.job_id,
      attempt_id: execution.attempt_id,
      source: "engine",
      turn: turn,
      provider: execution.provider,
      model: execution.model_resolved || execution.model,
      input_tokens: execution.prompt_tokens || 0,
      cached_input_tokens: nil,
      output_tokens: execution.completion_tokens || 0,
      reasoning_tokens: nil,
      cache_write_tokens: nil,
      occurred_at: DateTime.utc_now(:microsecond)
    })
  end

  @doc """
  Ledger rows for a task, oldest turn first. Used by the Cost / Turns tabs.
  """
  def list_for_task(task_id) when is_binary(task_id) do
    import Ecto.Query

    from(e in Entry,
      where: e.job_id == ^task_id,
      order_by: [asc: e.turn, asc: e.occurred_at]
    )
    |> Repo.all()
  end

  @doc """
  Measured `input + output` token spend for a task. Both columns are
  non-null integers on the ledger, so this is always a number (`0` when
  empty) — never nil.
  """
  @spec spent_tokens_for_task(Ecto.UUID.t()) :: non_neg_integer()
  def spent_tokens_for_task(task_id) when is_binary(task_id) do
    import Ecto.Query

    from(e in Entry,
      where: e.job_id == ^task_id,
      select: coalesce(sum(e.input_tokens + e.output_tokens), 0)
    )
    |> Repo.one()
  end

  @doc """
  Category cost rows for the Cost tab + `cost_breakdown`.

  Returns `%{rows: [map], total_tokens: integer | nil, total_cost: nil}`.

  * `input` / `output` — summed (always measured; missing rows contribute 0)
  * `cache read` / `cache write` / `reasoning` — **nullable aggregate**: if
    any row has `nil` for that field, the category total is `nil` (unknown),
    never a sum that treated nil as zero. Empty ledger → `rows: []`,
    `total_tokens: nil`.
  * `total_cost` is always `nil` — the ledger has no USD column.
  * `total_tokens` is `input + output` when both category sums are integers.
  """
  @spec cost_breakdown_for_task(Ecto.UUID.t()) :: %{
          rows: [map()],
          total_tokens: nil | non_neg_integer(),
          total_cost: nil
        }
  def cost_breakdown_for_task(task_id) when is_binary(task_id) do
    cost_breakdown(list_for_task(task_id))
  end

  @doc false
  def cost_breakdown([]), do: %{rows: [], total_tokens: nil, total_cost: nil}

  def cost_breakdown(entries) when is_list(entries) do
    input = sum_measured(entries, :input_tokens)
    output = sum_measured(entries, :output_tokens)

    rows = [
      %{label: "input", cost: nil, tokens: input},
      %{label: "output", cost: nil, tokens: output},
      %{label: "reasoning", cost: nil, tokens: sum_nullable(entries, :reasoning_tokens)},
      %{label: "cache read", cost: nil, tokens: sum_nullable(entries, :cached_input_tokens)},
      %{label: "cache write", cost: nil, tokens: sum_nullable(entries, :cache_write_tokens)}
    ]

    total =
      case {input, output} do
        {i, o} when is_integer(i) and is_integer(o) -> i + o
        _ -> nil
      end

    %{rows: rows, total_tokens: total, total_cost: nil}
  end

  # Measured columns default to 0 on the schema — sum treating absence as 0.
  defp sum_measured(entries, field) do
    Enum.reduce(entries, 0, fn entry, acc ->
      case Map.get(entry, field) do
        n when is_integer(n) -> acc + n
        _ -> acc
      end
    end)
  end

  # Nullable columns: any nil in the set → aggregate nil (unknown).
  defp sum_nullable(entries, field) do
    vals = Enum.map(entries, &Map.get(&1, field))

    if Enum.any?(vals, &is_nil/1) do
      nil
    else
      Enum.sum(vals)
    end
  end

  @doc """
  Sum of `input_tokens + output_tokens` for rows with `occurred_at` on the
  current UTC calendar day. Empty day → `0` (measured zero, not unknown).

  Cache-write tokens are **not** included — Overview "tokens today" is the
  billed in+out figure; budget guards elsewhere add cache_write separately.
  There is no daily cap in the domain; callers that need a denominator must
  pass `nil`, never invent one.
  """
  @spec tokens_today_utc() :: non_neg_integer()
  def tokens_today_utc do
    import Ecto.Query

    start = utc_day_start(DateTime.utc_now())

    from(e in Entry,
      where: e.occurred_at >= ^start,
      select: coalesce(sum(e.input_tokens + e.output_tokens), 0)
    )
    |> Repo.one()
  end

  @doc """
  Hourly token series for the last `hours` UTC hours (default 24), oldest
  first.

  Returns `%{values: [nil | number], peak: nil | number, avg: nil | number}`.
  Hours with no ledger rows are `nil` (gap), never coerced to `0`. `peak` /
  `avg` are over known hours only; both `nil` when every bucket is empty.
  No hourly/daily cap is returned — none exists in config.
  """
  @spec tokens_per_hour_utc(pos_integer()) :: %{
          values: [nil | number()],
          peak: nil | number(),
          avg: nil | number()
        }
  def tokens_per_hour_utc(hours \\ 24) when is_integer(hours) and hours > 0 do
    import Ecto.Query

    now = DateTime.utc_now()
    start = now |> DateTime.add(-(hours - 1) * 3600, :second) |> utc_hour_start()

    rows =
      from(e in Entry,
        where: e.occurred_at >= ^start,
        group_by: fragment("date_trunc('hour', ?)", e.occurred_at),
        select: {
          fragment("date_trunc('hour', ?)", e.occurred_at),
          coalesce(sum(e.input_tokens + e.output_tokens), 0)
        }
      )
      |> Repo.all()
      |> Map.new(fn {hour, tokens} -> {truncate_to_hour(hour), tokens} end)

    values =
      for offset <- 0..(hours - 1) do
        bucket = DateTime.add(start, offset * 3600, :second)
        Map.get(rows, bucket)
      end

    known = Enum.filter(values, &is_number/1)

    %{
      values: values,
      peak: if(known == [], do: nil, else: Enum.max(known)),
      avg:
        if known == [] do
          nil
        else
          Float.round(Enum.sum(known) / length(known), 1)
        end
    }
  end

  defp utc_day_start(%DateTime{} = dt) do
    {:ok, day} = DateTime.new(DateTime.to_date(dt), ~T[00:00:00], "Etc/UTC")
    DateTime.truncate(day, :microsecond)
  end

  defp utc_hour_start(%DateTime{} = dt) do
    {:ok, hour} =
      DateTime.new(DateTime.to_date(dt), Time.new!(dt.hour, 0, 0), "Etc/UTC")

    DateTime.truncate(hour, :microsecond)
  end

  defp truncate_to_hour(%DateTime{} = dt), do: utc_hour_start(dt)

  defp truncate_to_hour(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> utc_hour_start()
  end

  defp unique_request_id_error?(errors) do
    Enum.any?(errors, fn
      {:request_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
