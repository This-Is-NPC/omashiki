defmodule Omashiki.Worker.Local do
  @moduledoc """
  In-process worker transport.

  Delegates execution to the configured dispatch attempt runner while exposing
  the worker transport protocol used by remote workers in later phases.
  """

  @behaviour Omashiki.Worker.Transport

  alias Omashiki.Jobs.{Job, JobAttempt}
  alias Omashiki.Repo
  alias Omashiki.Runtime.AttemptSupervisor
  alias Omashiki.Worker.{Complete, Execution, Offer}

  @terminal ~w(succeeded failed cancelled)
  @sinks ~w(git files none)

  @impl Omashiki.Worker.Transport
  def offer(%Offer{} = offer) do
    with :ok <- validate_offer(offer) do
      {:ok, offer}
    end
  end

  @impl Omashiki.Worker.Transport
  def accept(%Offer{} = offer) do
    with :ok <- validate_offer(offer) do
      {:ok,
       %Execution{
         job_id: offer.job_id,
         attempt_id: offer.attempt_id,
         lease_token: offer.lease_token,
         sink: offer.sink
       }}
    end
  end

  @impl Omashiki.Worker.Transport
  def heartbeat(_execution), do: :ok

  @impl Omashiki.Worker.Transport
  def complete(_execution, %Complete{} = complete) do
    _ = Jason.encode!(Complete.to_map(complete))
    :ok
  end

  @impl Omashiki.Worker.Transport
  def execute(%Offer{} = offer, opts) do
    with {:ok, offer} <- offer(offer),
         {:ok, execution} <- accept(offer),
         {:ok, complete} <- run_offer(offer, opts),
         :ok <- complete(execution, complete) do
      {:ok, complete}
    end
  end

  defp run_offer(%Offer{attempt_id: attempt_id} = offer, opts) do
    attempt = Repo.get!(JobAttempt, attempt_id)
    timeout_ms = Keyword.get(opts, :await_timeout_ms, offer.timeout_ms)

    case runner().run(attempt, await_timeout_ms: timeout_ms) do
      {:ok, %Job{status: status}} when status in @terminal ->
        job = Repo.get!(Job, offer.job_id)
        complete = Complete.from_job(job)
        {:ok, complete}

      {:ok, _job} ->
        {:error, :runner_not_terminal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_offer(%Offer{
         job_id: job_id,
         attempt_id: attempt_id,
         lease_token: lease_token,
         sink: sink
       })
       when is_binary(job_id) and is_binary(attempt_id) and is_binary(lease_token) and
              sink in @sinks do
    :ok
  end

  defp validate_offer(_offer), do: {:error, :invalid_offer}

  defp runner,
    do: Application.get_env(:omashiki, :dispatch_attempt_runner, AttemptSupervisor)
end
