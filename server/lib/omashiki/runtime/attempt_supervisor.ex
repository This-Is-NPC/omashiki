defmodule Omashiki.Runtime.AttemptSupervisor do
  @moduledoc "Supervises one ephemeral runtime coordinator per active job attempt."

  use DynamicSupervisor

  import Ecto.Query

  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Repo
  alias Omashiki.Runtime.Attempt

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Run an attempt through its registered coordinator and wait for its terminal result."
  def run(%JobAttempt{} = attempt, opts \\ []) do
    spec = {Attempt, {attempt, opts}}
    await_timeout = Keyword.get(opts, :await_timeout_ms, default_await_timeout_ms())

    with {:ok, pid} <- start_attempt(spec),
         result when result != :await_timeout <- await_attempt(pid, attempt, await_timeout) do
      result
    else
      :await_timeout ->
        {:error, :dispatch_await_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason ->
      _ = fail_if_active(attempt, reason)
      {:error, {:attempt_process_exit, reason}}
  end

  defp start_attempt(spec) do
    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:attempt_start_failed, reason}}
    end
  end

  defp await_attempt(pid, _attempt, :infinity), do: Attempt.await(pid)

  defp await_attempt(pid, attempt, timeout) when is_integer(timeout) and timeout > 0 do
    try do
      Attempt.await(pid, timeout)
    catch
      :exit, {:timeout, _} ->
        stop_attempt_coordinator(pid, attempt)
        :await_timeout
    end
  end

  defp stop_attempt_coordinator(pid, attempt) do
    if Process.alive?(pid) do
      Attempt.cancel(pid)
      Process.exit(pid, :kill)
    end

    _ = fail_if_active(attempt, :dispatch_await_timeout)
  end

  defp default_await_timeout_ms do
    Application.get_env(:omashiki, :dispatch_await_timeout_ms, 3_660_000)
  end

  @doc "Interrupt the active runtime for a job after cancellation is durable."
  def cancel_job(job_id, attempt_number)
      when is_binary(job_id) and is_integer(attempt_number) and attempt_number > 0 do
    attempt_id =
      Repo.one(
        from(attempt in JobAttempt,
          where: attempt.job_id == ^job_id and attempt.number == ^attempt_number,
          limit: 1,
          select: attempt.id
        )
      )

    case Registry.lookup(Omashiki.Runtime.AttemptRegistry, {:attempt, attempt_id}) do
      [{pid, _value}] -> Attempt.cancel(pid)
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def cancel_job(_job_id, _attempt_number), do: :ok

  @doc "Best-effort failure fencing when an attempt coordinator exits unexpectedly."
  def fail_if_active(%JobAttempt{} = original, reason) do
    case Repo.get(JobAttempt, original.id) do
      %JobAttempt{status: status} = attempt when status in ["provisioning", "running"] ->
        Omashiki.Jobs.complete(attempt, attempt.lease_token, :failed, %{
          error: %{
            "code" => "attempt_process_exit",
            "message" => inspect(reason),
            "details" => %{}
          }
        })

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
