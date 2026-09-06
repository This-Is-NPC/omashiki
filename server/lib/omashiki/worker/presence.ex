defmodule Omashiki.Worker.Presence do
  @moduledoc false

  @table :omashiki_worker_presence

  @doc "Record or refresh a worker's last poll and reported capacity."
  def touch(machine_id, attrs) when is_binary(machine_id) and is_map(attrs) do
    ensure_table()

    entry =
      %{
        machine_id: machine_id,
        last_poll_at: Map.get(attrs, :last_poll_at) || now(),
        free_slots: Map.get(attrs, :free_slots, 0),
        metadata: Map.get(attrs, :metadata, %{})
      }
      |> Map.merge(Map.take(attrs, [:images]))

    true = :ets.insert(@table, {machine_id, entry})
    :ok
  end

  # A worker that stopped polling is not gone from the fleet, it is gone from
  # *this house*: it may still serve the others. Liveness here is per manager.
  @stale_after_seconds 30

  @doc "Return every worker seen on this manager, flagged stale after #{@stale_after_seconds}s."
  def list(now \\ now()) do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, attrs} ->
      Map.put(
        attrs,
        :stale?,
        DateTime.diff(now, attrs.last_poll_at, :second) > @stale_after_seconds
      )
    end)
    |> Enum.sort_by(& &1.machine_id)
  end

  @doc "Forget every worker (test hermeticity)."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
