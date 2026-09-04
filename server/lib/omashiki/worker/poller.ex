defmodule Omashiki.Worker.Poller do
  @moduledoc false

  use GenServer

  require Logger

  alias Omashiki.Worker.{Client, Complete, Execution, Offer, Slots}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    manager_url = Application.get_env(:omashiki, :manager_url)
    worker_token = Application.get_env(:omashiki, :worker_token)
    executor = Application.get_env(:omashiki, :worker_executor)
    machine_id = System.get_env("OMASHIKI_NODE") || hostname()
    interval_ms = Application.get_env(:omashiki, :worker_poll_interval_ms, 1_000)

    if missing_config?(manager_url, worker_token, executor) do
      Logger.warning(
        "Worker.Poller idle: manager_url, worker_token, and worker_executor must all be configured"
      )

      {:ok, %{mode: :idle}}
    else
      client = Client.new(manager_url, worker_token)
      slots = Keyword.get(opts, :slots, Slots)

      case Client.register(client, machine_id, free_slots(slots)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Worker.Poller register failed: #{inspect(reason)}")
      end

      state = %{
        mode: :active,
        client: client,
        executor: executor,
        machine_id: machine_id,
        interval_ms: interval_ms,
        slots: slots
      }

      send(self(), :tick)
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:tick, %{mode: :idle} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    free = free_slots(state.slots)

    state =
      if free == 0 do
        state
      else
        case Client.poll(state.client, state.machine_id, free) do
          {:ok, nil} ->
            state

          {:ok, %Offer{} = offer} ->
            handle_offer(state, offer)

          {:error, reason} ->
            Logger.warning("Worker.Poller poll failed: #{inspect(reason)}")
            state
        end
      end

    schedule_tick(state)
    {:noreply, state}
  end

  def handle_info({:job_finished, execution, offer, result}, state) do
    try do
      post_complete(state, execution, offer, result)
    after
      Slots.release(state.slots)
    end

    send(self(), :tick)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_offer(state, %Offer{} = offer) do
    execution = execution_from(offer)

    case Slots.try_acquire(state.slots) do
      {:error, :full} ->
        Logger.warning("Worker.Poller rejecting offer #{offer.job_id}: no local slots")
        Client.reject(state.client, execution)
        state

      :ok ->
        case Client.accept(state.client, execution) do
          :cancel ->
            Slots.release(state.slots)
            state

          {:error, reason} ->
            Logger.warning("Worker.Poller accept failed: #{inspect(reason)}")
            Slots.release(state.slots)
            Client.reject(state.client, execution)
            state

          :ok ->
            poller_pid = self()

            Task.start(fn ->
              result = run_executor(state.executor, offer)
              send(poller_pid, {:job_finished, execution, offer, result})
            end)

            send(self(), :tick)
            state
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

  defp post_complete(state, execution, offer, result) do
    case result do
      {:ok, %Complete{kind: :files} = complete} ->
        complete
        |> maybe_upload_blob(state.client, offer)
        |> then(&Client.complete(state.client, execution, &1))

      {:ok, %Complete{} = complete} ->
        Client.complete(state.client, execution, complete)

      {:error, reason} ->
        error_complete = %Complete{
          kind: :error,
          code: "executor_failed",
          message: Exception.format(:error, reason, [])
        }

        Client.complete(state.client, execution, error_complete)
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
      sink: offer.sink
    }
  end

  defp free_slots(slots), do: Slots.available(slots)

  defp schedule_tick(%{mode: :idle}), do: :ok

  defp schedule_tick(%{interval_ms: interval_ms}) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp missing_config?(manager_url, worker_token, executor) do
    blank?(manager_url) or blank?(worker_token) or is_nil(executor)
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_), do: false

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
