defmodule Omashiki.Worker.Poller do
  @moduledoc false

  use GenServer

  require Logger

  alias Omashiki.Runtime.ContainerTracker
  alias Omashiki.Worker.{Client, Complete, Execution, Managers, Offer, Slots}

  # A container change is reported to the managers almost at once; the
  # keepalive report keeps slots current while the worker is too busy to poll.
  @report_debounce_ms 150
  @report_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Activate or refresh the poll loop after enrollment or config changes."
  @spec configure(keyword()) :: :ok
  def configure(opts \\ []) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    GenServer.call(server, {:configure, opts})
  end

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Omashiki.PubSub, ContainerTracker.topic())
    {:ok, build_state(opts)}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    new_state = build_state(Keyword.merge(default_opts(state), opts))
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:tick, %{mode: :idle} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = heartbeat_in_flight(state)
    free = free_slots(state.slots)

    state =
      if free == 0 do
        state
      else
        poll_next_manager(state, free)
      end

    state = maybe_report(state)
    schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(:containers_changed, %{mode: :active, report_pending: false} = state) do
    Process.send_after(self(), :report, @report_debounce_ms)
    {:noreply, %{state | report_pending: true}}
  end

  def handle_info(:report, %{mode: :active} = state), do: {:noreply, report_all(state)}

  def handle_info({:job_finished, _execution, offer, result}, state) do
    attempt_id = offer.attempt_id

    case Map.fetch(state.in_flight, attempt_id) do
      {:ok, %{client: client, execution: execution}} ->
        try do
          post_complete(client, execution, offer, result)
        after
          Slots.release(state.slots)
        end

        state = update_in(state.in_flight, &Map.delete(&1, attempt_id))
        send(self(), :tick)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll_next_manager(state, free) do
    managers = state.managers
    count = length(managers)
    idx = state.rr
    manager = Enum.at(managers, idx)
    rr = rem(idx + 1, count)
    state = %{state | rr: rr}

    case Client.poll(manager.client, state.machine_id, free) do
      {:ok, nil} ->
        state

      {:ok, %Offer{} = offer} ->
        offer = %{offer | manager_id: manager.id, manager_url: manager.url}
        handle_offer(state, offer, manager.client)

      {:error, reason} ->
        Logger.warning("Worker.Poller poll failed for #{manager.id}: #{inspect(reason)}")

        state
    end
  end

  defp heartbeat_in_flight(state) do
    Enum.reduce(state.in_flight, state, fn {attempt_id, job}, acc ->
      case Client.heartbeat(job.client, job.execution) do
        :cancel ->
          if Process.alive?(job.task_pid), do: Process.exit(job.task_pid, :kill)
          Slots.release(acc.slots)
          %{acc | in_flight: Map.delete(acc.in_flight, attempt_id)}

        _ ->
          acc
      end
    end)
  end

  defp handle_offer(state, %Offer{} = offer, client) do
    execution = execution_from(offer)

    case Slots.try_acquire(state.slots) do
      {:error, :full} ->
        Logger.warning("Worker.Poller rejecting offer #{offer.job_id}: no local slots")
        Client.reject(client, execution)
        state

      :ok ->
        case Client.accept(client, execution) do
          :cancel ->
            Slots.release(state.slots)
            state

          {:error, reason} ->
            Logger.warning("Worker.Poller accept failed: #{inspect(reason)}")
            Slots.release(state.slots)
            Client.reject(client, execution)
            state

          :ok ->
            poller_pid = self()

            {:ok, task_pid} =
              Task.start(fn ->
                result = run_executor(state.executor, offer)
                send(poller_pid, {:job_finished, execution, offer, result})
              end)

            in_flight =
              Map.put(state.in_flight, offer.attempt_id, %{
                execution: execution,
                offer: offer,
                client: client,
                task_pid: task_pid
              })

            send(self(), :tick)
            %{state | in_flight: in_flight}
        end
    end
  end

  defp run_executor(executor, offer) do
    try do
      executor.run(offer)
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp post_complete(client, execution, offer, result) do
    case result do
      {:ok, %Complete{kind: :files} = complete} ->
        complete
        |> maybe_upload_blob(client, offer)
        |> then(&Client.complete(client, execution, &1))

      {:ok, %Complete{} = complete} ->
        Client.complete(client, execution, complete)

      {:error, reason} ->
        error_complete = %Complete{
          kind: :error,
          code: "executor_failed",
          message: Exception.format(:error, reason, [])
        }

        Client.complete(client, execution, error_complete)
    end
  end

  defp maybe_upload_blob(%Complete{kind: :files} = complete, client, %Offer{job_id: job_id}) do
    with path when is_binary(path) <- complete.blob_path,
         true <- File.exists?(path),
         binary <- File.read!(path),
         digest when is_binary(digest) <- complete.blob_digest || sha256_hex(binary),
         :ok <- Client.put_blob(client, job_id, digest, binary) do
      %{complete | blob_digest: digest, blob_path: nil}
    else
      _ -> complete
    end
  end

  defp execution_from(%Offer{} = offer) do
    %Execution{
      job_id: offer.job_id,
      attempt_id: offer.attempt_id,
      lease_token: offer.lease_token,
      sink: offer.sink,
      manager_id: offer.manager_id
    }
  end

  defp maybe_report(%{mode: :active} = state) do
    if System.monotonic_time(:millisecond) - state.last_report_at >= state.report_ms,
      do: report_all(state),
      else: state
  end

  defp report_all(state) do
    containers = ContainerTracker.list()
    %{max: capacity, free: free} = Slots.snapshot(state.slots)

    for manager <- state.managers do
      mine = containers_for_manager(containers, state.in_flight, manager.id)

      case Client.report(manager.client, state.machine_id, free, capacity, mine) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("Worker.Poller report to #{manager.id}: #{inspect(reason)}")
      end
    end

    %{state | last_report_at: System.monotonic_time(:millisecond), report_pending: false}
  end

  @doc """
  The containers a manager may see: only those running its own in-flight
  attempts. A worker shared by several houses never shows one house another's
  containers, and a container no attempt owns is reported to nobody.
  """
  def containers_for_manager(containers, in_flight, manager_id) do
    attempts =
      for {attempt_id, %{offer: %{manager_id: ^manager_id}}} <- in_flight,
          into: MapSet.new(),
          do: attempt_id

    Enum.filter(containers, &MapSet.member?(attempts, &1.attempt_id))
  end

  defp free_slots(slots), do: Slots.available(slots)

  defp schedule_tick(%{mode: :idle}), do: :ok

  defp schedule_tick(%{interval_ms: interval_ms}) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp build_state(opts) do
    managers = Keyword.get(opts, :managers) || Managers.configured()
    executor = Keyword.get(opts, :executor) || Application.get_env(:omashiki, :worker_executor)
    machine_id = Keyword.get(opts, :machine_id) || System.get_env("OMASHIKI_NODE") || hostname()
    interval_ms = Application.get_env(:omashiki, :worker_poll_interval_ms, 1_000)
    slots = Keyword.get(opts, :slots, Slots)

    if managers == [] or is_nil(executor) do
      Logger.warning(
        "Worker.Poller idle: at least one manager and worker_executor must be configured"
      )

      %{mode: :idle, slots: slots}
    else
      managers =
        Enum.map(managers, fn m ->
          %{id: m.id, url: m.url, client: Client.new(m.url, m.token)}
        end)

      for m <- managers do
        case Client.register(m.client, machine_id, free_slots(slots)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Worker.Poller register failed for #{m.id}: #{inspect(reason)}")
        end
      end

      state = %{
        mode: :active,
        managers: managers,
        rr: 0,
        in_flight: %{},
        executor: executor,
        machine_id: machine_id,
        interval_ms: interval_ms,
        slots: slots,
        report_ms: Application.get_env(:omashiki, :worker_fleet_report_ms, @report_ms),
        last_report_at: System.monotonic_time(:millisecond),
        report_pending: false
      }

      send(self(), :tick)
      state
    end
  end

  defp default_opts(%{slots: slots}) when is_atom(slots) or is_pid(slots), do: [slots: slots]
  defp default_opts(_), do: []

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp sha256_hex(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end
end
