defmodule Omashiki.Jobs.HeldOutput.Sweeper do
  @moduledoc """
  Settles the output this node holds for review.

  Every few seconds, and on an embedded house soon after a job changes, it
  asks the house about each record in `Omashiki.Jobs.HeldOutput` through the
  attempt heartbeat, the channel that carries cancellation to a node. The
  answer keeps the output, publishes it (the job was approved), or removes it
  (the job was rejected, cancelled or expired, or the house no longer knows
  the attempt). A published record's complete goes back through the same
  completion as any attempt.

  An embedded house asks its own `Omashiki.Worker.Inbox`; a worker asks the
  manager that offered the attempt, over HTTP. A manager that refuses the
  worker's token (401 or 403) will never decide, so the output goes at once.
  Otherwise a record waits while its manager is unreachable or no longer
  configured, until an hour past the record's own deadline: then the output
  goes whether or not the house answers, since the house has failed the job
  by then.
  """

  use GenServer

  require Logger

  alias Omashiki.Jobs.HeldOutput
  alias Omashiki.Worker.{Client, Complete, Execution, Inbox, Managers}

  @interval_ms 5_000
  @debounce_ms 250
  # Covers clock skew between the node and the house, and the house's own
  # expiry tick, so the house fails the job before the node drops its output.
  @grace_ms :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take one step for `record`: ask, then publish, deliver, or discard.
  Returns what happened; `:held` and `{:error, reason}` keep the record,
  anything else removed or advanced it. `{:discarded, reason}` says why the
  output went: `:cancelled` (the house told it to), `:unauthorized` (the
  manager refused the worker), `:expired` (past the deadline and its grace),
  or `{:complete_refused, reason}`.
  """
  @spec settle(HeldOutput.t()) ::
          :held | :published | :delivered | {:discarded, term()} | {:error, term()}
  def settle(%HeldOutput{complete: nil} = record) do
    case command(record) do
      :cancel ->
        discard(record, :cancelled)

      {:error, :unauthorized} ->
        discard(record, :unauthorized)

      :publish ->
        with {:ok, record} <- HeldOutput.publish(record) do
          case deliver(record) do
            :delivered -> :published
            other -> other
          end
        end

      answer ->
        wait(record, answer)
    end
  end

  def settle(%HeldOutput{} = record) do
    case deliver(record) do
      {:error, _reason} = error -> wait(record, error)
      other -> other
    end
  end

  # Past its deadline and the grace, the output goes whatever the house says:
  # the house has failed the job by then, or cannot be asked.
  defp wait(record, answer) do
    removal_at = DateTime.add(record.expires_at, @grace_ms, :millisecond)

    cond do
      DateTime.after?(DateTime.utc_now(), removal_at) -> discard(record, :expired)
      answer == :ok -> :held
      true -> answer
    end
  end

  defp discard(record, reason) do
    HeldOutput.discard(record)
    {:discarded, reason}
  end

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Omashiki.PubSub, "jobs")
    send(self(), :sweep)

    {:ok,
     %{
       interval_ms: Keyword.get(opts, :interval_ms, interval_ms()),
       busy: %{},
       timer: nil,
       pending: false
     }}
  end

  @impl true
  def handle_info(:sweep, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    busy =
      Enum.reduce(HeldOutput.list(), state.busy, fn record, busy ->
        if record.attempt_id in Map.values(busy) do
          busy
        else
          task =
            Task.Supervisor.async_nolink(Omashiki.Runtime.TaskSupervisor, fn -> settle(record) end)

          Map.put(busy, task.ref, record.attempt_id)
        end
      end)

    timer = Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, %{state | busy: busy, timer: timer, pending: false}}
  end

  # A decision on an embedded house arrives as a job change; bursts of step
  # changes are folded into one sweep.
  def handle_info({:job_updated, _job_id}, %{pending: false} = state) do
    Process.send_after(self(), :sweep, @debounce_ms)
    {:noreply, %{state | pending: true}}
  end

  def handle_info({ref, result}, state) when is_map_key(state.busy, ref) do
    Process.demonitor(ref, [:flush])
    log(state.busy[ref], result)
    {:noreply, %{state | busy: Map.delete(state.busy, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.busy, ref) do
    Logger.warning("held output of #{state.busy[ref]} could not be settled: #{inspect(reason)}")
    {:noreply, %{state | busy: Map.delete(state.busy, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp log(attempt_id, {:error, reason}),
    do: Logger.warning("held output of #{attempt_id} could not be settled: #{inspect(reason)}")

  defp log(attempt_id, :published),
    do: Logger.info("published the approved output of attempt #{attempt_id}")

  # A house that decided is routine; any other end of held output is not.
  defp log(attempt_id, {:discarded, reason}) do
    level = if reason == :cancelled, do: :info, else: :warning
    Logger.log(level, "removed the held output of attempt #{attempt_id}: #{why(reason)}")
  end

  defp log(_attempt_id, _result), do: :ok

  defp why(:cancelled),
    do: "the house rejected, cancelled or expired the job, or no longer knows the attempt"

  defp why(:unauthorized), do: "the manager refused this worker's token"
  defp why(:expired), do: "its review deadline passed and the house did not settle it"
  defp why({:complete_refused, reason}), do: "the house refused its complete: #{inspect(reason)}"

  defp command(%HeldOutput{manager_id: nil} = record) do
    {:ok, command} = Inbox.held(record.attempt_id, record.token)
    command
  end

  defp command(record) do
    with {:ok, client} <- client(record), do: Client.held(client, execution(record))
  end

  # A complete the house turns down for good cannot succeed later: the output
  # goes. Any other failure is retried on the next sweep, up to the deadline.
  defp deliver(%HeldOutput{manager_id: nil} = record) do
    case Inbox.complete(record.attempt_id, record.token, Complete.to_map(record.complete)) do
      {:ok, _attempt} -> finish(record)
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> discard(record, {:complete_refused, reason})
    end
  end

  defp deliver(record) do
    with {:ok, client} <- client(record) do
      complete = Client.upload_blob(client, record.job_id, record.complete)

      case Client.complete(client, execution(record), complete) do
        :ok ->
          finish(record)

        {:error, :unauthorized} ->
          discard(record, :unauthorized)

        {:error, {:http, status, _body} = reason} when status in 400..499 ->
          discard(record, {:complete_refused, reason})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp finish(record) do
    HeldOutput.finish(record)
    :delivered
  end

  defp client(%HeldOutput{manager_id: manager_id}) do
    case Enum.find(Managers.configured(), &(&1.id == manager_id)) do
      %{url: url, token: token} -> {:ok, Client.new(url, token)}
      nil -> {:error, {:manager_not_enrolled, manager_id}}
    end
  end

  defp execution(record) do
    %Execution{
      job_id: record.job_id,
      attempt_id: record.attempt_id,
      lease_token: record.token,
      sink: record.sink,
      manager_id: record.manager_id
    }
  end

  defp interval_ms, do: Application.get_env(:omashiki, :held_output_sweep_ms, @interval_ms)
end
