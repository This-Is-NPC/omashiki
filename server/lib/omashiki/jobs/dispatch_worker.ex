defmodule Omashiki.Jobs.DispatchWorker do
  @moduledoc """
  Durable one-job dispatch boundary backed by the jobs table.

  Oban discarding a dispatch must never be the last word on a `jobs` row.
  Every path that ends in an Oban error settles the row into a terminal
  state first, so a lost dispatch is always visible as `failed`/`cancelled`
  with a `terminal_error` rather than a row silently parked at `queued`
  (NFR-001). Retries exist only for the window where a retry can still
  help: the row is still `queued` because the claim itself failed.
  """

  require Logger

  @max_attempts 5

  use Oban.Worker,
    queue: :scheduler,
    max_attempts: @max_attempts,
    unique: [
      period: :infinity,
      keys: [:job_id],
      states: :incomplete
    ]

  alias Omashiki.Jobs
  alias Omashiki.Jobs.Job
  alias Omashiki.Repo
  alias Omashiki.Runtime.AttemptSupervisor

  @terminal ~w(succeeded failed cancelled)
  @active ~w(provisioning running)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: trunc(:math.pow(2, attempt)) + :rand.uniform(5)

  @impl Oban.Worker
  def perform(%Oban.Job{} = oban_job) do
    oban_job
    |> guarded_dispatch()
    |> settle(oban_job)
  end

  defp guarded_dispatch(%Oban.Job{args: %{"job_id" => job_id}} = oban_job) do
    dispatch(oban_job)
  rescue
    error ->
      Logger.error(
        "dispatch crashed for job #{job_id}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, {:dispatch_exception, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error("dispatch exited for job #{job_id}: #{inspect({kind, reason})}")
      {:error, {:dispatch_exit, kind, reason}}
  end

  defp dispatch(%Oban.Job{id: oban_id, args: %{"job_id" => job_id}}) do
    case Repo.get(Job, job_id) do
      nil ->
        {:cancel, :job_missing}

      %Job{status: "queued"} ->
        case Jobs.claim(job_id, "oban:#{oban_id}") do
          {:ok, attempt} ->
            case attempt_runner().run(attempt) do
              {:ok, %Job{status: status}} when status in @terminal ->
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

  # Oban is about to record an error. Before it does, make sure the jobs row
  # carries a terminal state of its own, so nothing is lost silently.
  defp settle({:error, reason} = result, %Oban.Job{args: %{"job_id" => job_id}} = oban_job) do
    _ = terminate_stranded(job_id, reason, final_attempt?(oban_job))
    result
  end

  defp settle(result, _oban_job), do: result

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}),
    do: attempt >= max_attempts

  defp terminate_stranded(job_id, reason, final?) do
    case Repo.get(Job, job_id) do
      nil ->
        :ok

      %Job{status: status} when status in @terminal ->
        :ok

      %Job{status: status} = job when status in @active ->
        # The attempt is already burnt: a retry would only see `not_queued`.
        force_terminal(job, reason)

      %Job{} = job ->
        # Still dispatchable. Let Oban retry until the budget is gone.
        if final?, do: force_terminal(job, reason), else: :ok
    end
  end

  defp force_terminal(%Job{status: status} = job, reason) when status in @active do
    error = dispatch_error(reason)

    case Jobs.fail(job.id, %{error: error}) do
      {:ok, _job} -> :ok
      {:error, _reason} -> force_cancel(job, error)
    end
  end

  defp force_terminal(%Job{} = job, reason), do: force_cancel(job, dispatch_error(reason))

  # A job row that never started cannot become `failed` (see the
  # `jobs_start_timestamps` check constraint); `cancelled` is the terminal
  # state the schema reserves for it.
  defp force_cancel(%Job{} = job, error) do
    case Jobs.cancel(job.id, %{error: error}) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("dispatch could not terminate job #{job.id}: #{inspect(reason)}")
        :error
    end
  end

  defp dispatch_error(reason) do
    %{
      "code" => "dispatch_failed",
      "message" =>
        reason
        |> inspect(limit: 5, printable_limit: 200)
        |> String.slice(0, 240),
      "details" => %{}
    }
  end

  defp attempt_runner,
    do: Application.get_env(:omashiki, :dispatch_attempt_runner, AttemptSupervisor)
end
