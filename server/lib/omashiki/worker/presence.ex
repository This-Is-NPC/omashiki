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

  @doc "Return every worker seen on this manager."
  def list do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, attrs} -> attrs end)
    |> Enum.sort_by(& &1.machine_id)
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
