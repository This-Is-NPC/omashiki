defmodule Omashiki.Jobs.Recovery do
  @moduledoc """
  Periodically reconciles expired local leases after worker or server death,
  queued jobs whose dispatch was lost, and held output past its review
  deadline.
  """

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
    with {:ok, recovered} when recovered > 0 <-
           sweep(
             &Omashiki.Jobs.recover_stale/0,
             "recovered ~s stale job attempt(s)",
             "stale attempt recovery failed"
           ) do
      remove_dead_containers()
    end

    sweep(
      &Omashiki.Jobs.recover_orphaned_dispatches/0,
      "cancelled ~s job(s) whose dispatch was lost",
      "orphaned dispatch recovery failed"
    )

    sweep(
      &Omashiki.Jobs.expire_reviews/0,
      "failed ~s job(s) whose output waited too long for review",
      "review expiry failed"
    )

    Process.send_after(self(), :recover, @interval_ms)
    {:noreply, state}
  end

  # Each sweep is independent: one failing must not cost the other its tick.
  defp sweep(run, success, failure) do
    case run.() do
      {:ok, 0} = result ->
        result

      {:ok, count} = result ->
        Logger.info(String.replace(success, "~s", Integer.to_string(count)))
        result

      {:error, reason} = result ->
        Logger.warning("#{failure}: #{inspect(reason)}")
        result
    end
  end

  # A stale attempt's container outlives it: boot cleanup ran while the attempt
  # still looked alive. Once the attempt is failed its container is an orphan,
  # so reclaim it now. Only where this node runs both the database and Docker:
  # a worker-role node has no attempts to compare against and would see every
  # container as an orphan. A remote worker learns which of its containers are
  # dead from its manager's answer to each report (`Omashiki.Worker.Poller`).
  defp remove_dead_containers do
    if Omashiki.Application.boot_role() == :embedded and
         Process.whereis(Omashiki.Runtime.ContainerManager) do
      case Omashiki.Runtime.ContainerManager.cleanup_orphans() do
        {:ok, [_ | _] = removed} ->
          Logger.info("removed #{length(removed)} container(s) of stale attempts")

        {:ok, []} ->
          :ok

        {:error, reason} ->
          Logger.warning("stale attempt container cleanup failed: #{inspect(reason)}")
      end
    end

    :ok
  end
end
