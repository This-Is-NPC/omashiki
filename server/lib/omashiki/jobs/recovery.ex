defmodule Omashiki.Jobs.Recovery do
  @moduledoc "Periodically reconciles expired local leases after worker or server death."

  use GenServer

  require Logger

  @interval_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :recover)
    {:ok, nil}
  end

  @impl true
  def handle_info(:recover, state) do
    case Omashiki.Jobs.recover_stale() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("recovered #{count} stale job attempt(s)")
      {:error, reason} -> Logger.warning("stale attempt recovery failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :recover, @interval_ms)
    {:noreply, state}
  end
end
