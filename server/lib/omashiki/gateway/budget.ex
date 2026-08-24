defmodule Omashiki.Gateway.Budget do
  @moduledoc """
  Token budget guard applied **between turns**, never mid-stream.

  Ceilings (first match that is set wins as a hard cap; all are checked):

  * `jobs.payload.budget_tokens`
  * Application env `:global_budget_tokens`

  Spend is `sum(input + output)` plus `sum(cache_write)` over **known**
  rows only (`SUM` skips SQL NULL — unknown cache never invents zero spend).
  Called from `Omashiki.Gateway` before forwarding and from
  `ExecutionDriver` before `send_turn` so a turn never starts when over budget.
  """

  import Ecto.Query

  alias Omashiki.Jobs.Job
  alias Omashiki.Repo
  alias Omashiki.UsageLedger.Entry

  @doc """
  Returns `:ok` or `{:error, :budget_exceeded}`.
  """
  def check(%Job{} = job) do
    spent_job = spent_for_job(job.id)
    job_budget = get_in(job.payload || %{}, ["budget_tokens"])

    cond do
      over?(job_budget, spent_job) ->
        {:error, :budget_exceeded}

      over?(global_budget(), spent_global()) ->
        {:error, :budget_exceeded}

      true ->
        :ok
    end
  end

  def check(job_id) when is_binary(job_id) do
    case Repo.get(Job, job_id) do
      nil -> :ok
      job -> check(job)
    end
  end

  defp global_budget do
    Application.get_env(:omashiki, :global_budget_tokens)
  end

  defp over?(nil, _), do: false
  defp over?(cap, spent) when is_integer(cap) and is_integer(spent), do: spent >= cap
  defp over?(_, _), do: false

  def spent_for_job(job_id) do
    base =
      from(e in Entry,
        where: e.job_id == ^job_id,
        select: coalesce(sum(e.input_tokens + e.output_tokens), 0)
      )
      |> Repo.one() || 0

    cache =
      from(e in Entry,
        where: e.job_id == ^job_id,
        select: coalesce(sum(e.cache_write_tokens), 0)
      )
      |> Repo.one() || 0

    base + cache
  end

  def spent_global do
    base =
      from(e in Entry, select: coalesce(sum(e.input_tokens + e.output_tokens), 0))
      |> Repo.one() || 0

    cache =
      from(e in Entry, select: coalesce(sum(e.cache_write_tokens), 0))
      |> Repo.one() || 0

    base + cache
  end
end
