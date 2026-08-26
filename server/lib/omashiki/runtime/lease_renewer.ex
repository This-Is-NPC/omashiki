defmodule Omashiki.Runtime.LeaseRenewer do
  @moduledoc """
  Renews every live attempt lease in one statement per tick.

  Each attempt used to renew on its own: a transaction plus `SELECT … FOR
  UPDATE` plus an update, once per interval. That is fine at ten attempts and
  becomes the dominant database cost at four hundred, where the renewals
  compete with admission and with each other for pool connections — and an
  attempt that loses that race is failed as `stale_attempt` even though it is
  healthy.

  Refreshing is a blind conditional update, so it needs no row lock: the
  `lease_token` match *is* the fence. An attempt whose row does not come back
  has been fenced, finished, or expired, and is told so directly.
  """

  use GenServer

  alias Omashiki.Repo

  require Logger

  @interval_ms 5_000
  @lease_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Track `attempt_id` until it is unregistered or its lease is lost."
  def register(server \\ __MODULE__, attempt_id, lease_token)
      when is_binary(attempt_id) and is_binary(lease_token) and lease_token != "" do
    GenServer.cast(server, {:register, attempt_id, lease_token, self()})
  end

  def unregister(server \\ __MODULE__, attempt_id) when is_binary(attempt_id) do
    GenServer.cast(server, {:unregister, attempt_id})
  end

  @doc "Lease window a renewed attempt gets. Longer than the tick, deliberately."
  def lease_ms, do: @lease_ms

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    schedule(interval)

    {:ok,
     %{tracked: %{}, interval_ms: interval, lease_ms: Keyword.get(opts, :lease_ms, @lease_ms)}}
  end

  @impl true
  def handle_cast({:register, attempt_id, lease_token, pid}, state) do
    {:noreply, put_in(state.tracked[attempt_id], {lease_token, pid})}
  end

  def handle_cast({:unregister, attempt_id}, state) do
    {:noreply, %{state | tracked: Map.delete(state.tracked, attempt_id)}}
  end

  @impl true
  def handle_info(:renew, %{tracked: tracked} = state) when map_size(tracked) == 0 do
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:renew, state) do
    state =
      case renew(state) do
        {:ok, refreshed} -> drop_lost(state, refreshed)
        {:error, reason} -> tap(state, fn _ -> log_failure(reason) end)
      end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp renew(%{tracked: tracked, lease_ms: lease_ms}) do
    ids = Map.keys(tracked)
    tokens = Enum.map(ids, fn id -> tracked |> Map.fetch!(id) |> elem(0) end)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    until = DateTime.add(now, lease_ms, :millisecond)

    sql = """
    UPDATE job_attempts AS a
    SET heartbeat_at = $1, lease_expires_at = $2, updated_at = $1
    FROM unnest($3::uuid[], $4::text[]) AS v(id, token)
    WHERE a.id = v.id
      AND a.lease_token = v.token
      AND a.status IN ('provisioning', 'running')
    RETURNING a.id
    """

    case Repo.query(sql, [now, until, Enum.map(ids, &dump_uuid/1), tokens]) do
      {:ok, %{rows: rows}} -> {:ok, MapSet.new(rows, fn [id] -> load_uuid(id) end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A row that did not come back is no longer ours to renew. Telling the owner
  # is what keeps this equivalent to the per-attempt heartbeat it replaces.
  defp drop_lost(state, refreshed) do
    {kept, lost} =
      Enum.split_with(state.tracked, fn {id, _} -> MapSet.member?(refreshed, id) end)

    Enum.each(lost, fn {id, {_token, pid}} ->
      send(pid, {:lease_lost, id})
    end)

    %{state | tracked: Map.new(kept)}
  end

  defp log_failure(reason) do
    Logger.warning("[LeaseRenewer] batch renewal failed: #{inspect(reason)}")
  end

  defp schedule(interval), do: Process.send_after(self(), :renew, interval)

  defp dump_uuid(id) do
    {:ok, dumped} = Ecto.UUID.dump(id)
    dumped
  end

  defp load_uuid(raw) when is_binary(raw) do
    case Ecto.UUID.load(raw) do
      {:ok, id} -> id
      :error -> raw
    end
  end
end
