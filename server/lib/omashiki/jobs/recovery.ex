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
    sweep(
      &Omashiki.Jobs.recover_stale/0,
      "recovered ~s stale job attempt(s)",
      "stale attempt recovery failed"
    )

    sweep(
      &Omashiki.Jobs.recover_orphaned_dispatches/0,
      "cancelled ~s job(s) whose dispatch was lost",
      "orphaned dispatch recovery failed"
    )

    Process.send_after(self(), :recover, @interval_ms)
    {:noreply, state}
  end

  # Each sweep is independent: one failing must not cost the other its tick.
  defp sweep(run, success, failure) do
    case run.() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info(String.replace(success, "~s", Integer.to_string(count)))

      {:error, reason} ->
        Logger.warning("#{failure}: #{inspect(reason)}")
    end
  end
end
