defmodule Omashiki.Worker.Presence do
  @moduledoc false

  alias Omashiki.Fleet

  @table :omashiki_worker_presence

  @doc "Record or refresh a worker's last poll and reported capacity."
  def touch(machine_id, attrs) when is_binary(machine_id) and is_map(attrs) do
    ensure_table()
    previous = lookup(machine_id)

    entry =
      %{
        machine_id: machine_id,
        last_poll_at: Map.get(attrs, :last_poll_at) || now(),
        free_slots: Map.get(attrs, :free_slots, 0),
        metadata: Map.get(attrs, :metadata, %{})
      }
      |> Map.merge(Map.take(attrs, [:images]))
      # A poll carries no container list; keep the last report's.
      |> Map.merge(Map.take(previous || %{}, [:capacity, :containers]))

    true = :ets.insert(@table, {machine_id, entry})
    announce(previous, entry, [:free_slots])
  end

  @doc """
  Record a worker's full report: free slots, total capacity, and the containers
  it runs for this house. Announces the worker only when something changed.
  """
  def report(machine_id, %{free_slots: free_slots, capacity: capacity, containers: containers})
      when is_binary(machine_id) and is_list(containers) do
    ensure_table()
    previous = lookup(machine_id) || %{}

    entry =
      %{
        machine_id: machine_id,
        last_poll_at: now(),
        free_slots: free_slots,
        metadata: Map.get(previous, :metadata, %{}),
        capacity: capacity,
        containers: containers
      }
      |> Map.merge(Map.take(previous, [:images]))

    true = :ets.insert(@table, {machine_id, entry})

    announce(if(previous == %{}, do: nil, else: previous), entry, [
      :free_slots,
      :capacity,
      :containers
    ])
  end

  # A worker that stopped polling is not gone from the fleet, it is gone from
  # *this house*: it may still serve the others. Liveness here is per manager.
  @stale_after_seconds 30

  @doc "Return every worker seen on this manager, flagged stale after #{@stale_after_seconds}s."
  def list(now \\ now()) do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, attrs} -> Map.put(attrs, :stale?, stale?(attrs, now)) end)
    |> Enum.sort_by(& &1.machine_id)
  end

  @doc "Forget every worker (test hermeticity)."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Create the table if it is missing. `Omashiki.Application` calls this at boot
  so a long-lived process owns it: a table created lazily by a request process
  is deleted with that process, and every poll recorded in it is lost.
  """
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp lookup(machine_id) do
    case :ets.lookup(@table, machine_id) do
      [{^machine_id, entry}] -> entry
      [] -> nil
    end
  end

  # New, back from stale, or a watched field changed: the fleet looks different.
  defp announce(previous, entry, fields) do
    if is_nil(previous) or stale?(previous, now()) or
         Map.take(previous, fields) != Map.take(entry, fields) do
      Fleet.broadcast_updated(entry.machine_id)
    end

    :ok
  end

  defp stale?(%{last_poll_at: last_poll_at}, now),
    do: DateTime.diff(now, last_poll_at, :second) > @stale_after_seconds

  defp now, do: DateTime.utc_now(:microsecond)
end
