defmodule Omashiki.Jobs.DispatchWorker do
  @moduledoc "Durable one-job dispatch boundary backed by the jobs table."

  use Oban.Worker,
    queue: :scheduler,
    max_attempts: 1,
    unique: [
      period: :infinity,
      keys: [:job_id],
      states: :incomplete
    ]

  alias Omashiki.Jobs
  alias Omashiki.Jobs.Job
  alias Omashiki.Repo
  alias Omashiki.Runtime.AttemptSupervisor

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"job_id" => job_id}}) do
    case Repo.get(Job, job_id) do
      nil ->
        {:cancel, :job_missing}

      %Job{status: "queued"} ->
        case Jobs.claim(job_id, "oban:#{oban_id}") do
          {:ok, attempt} ->
            case AttemptSupervisor.run(attempt) do
              {:ok, %Job{status: status}} when status in ["succeeded", "failed", "cancelled"] ->
                :ok

              {:ok, _job} ->
                {:error, :runner_not_terminal}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :capacity_exhausted} ->
            {:snooze, 1}

          {:error, {:not_queued, status}} ->
            {:cancel, {:not_queued, status}}

          {:error, reason} ->
            {:error, reason}
        end

      %Job{status: status} ->
        {:cancel, {:not_queued, status}}
    end
  end
end
