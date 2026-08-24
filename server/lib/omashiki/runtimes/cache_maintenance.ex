defmodule Omashiki.Runtimes.CacheMaintenance do
  @moduledoc """
  Periodic coordinator for cache snapshots, bounded eviction, and leases.

  The coordinator owns only in-memory lease state. Durable cache metadata is
  written by `Omashiki.Runtimes.CacheGc` outside the mounted payload, so a
  coordinator restart cannot leave a cache permanently leased.
  """

  use GenServer
  require Logger

  alias Omashiki.Runtimes.{CacheGc, CacheGroup}

  @default_interval_ms 15 * 60 * 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs maintenance immediately for all configured groups."
  def run(server \\ __MODULE__), do: GenServer.call(server, :run, 120_000)

  @doc "Returns one current snapshot."
  def snapshot(group, server \\ __MODULE__),
    do: GenServer.call(server, {:snapshot, group}, 30_000)

  @doc "Returns current snapshots for all configured groups, for an operator view."
  def snapshots(server \\ __MODULE__), do: GenServer.call(server, :snapshots, 60_000)

  @doc "Marks a group as used without touching mounted payload contents."
  def touch(group, server \\ __MODULE__), do: GenServer.call(server, {:touch, group}, 30_000)

  @doc "Records a cold/warm cache observation and its provisioning/install time."
  def record_access(group, outcome, duration_ms, server \\ __MODULE__)
      when outcome in [:cold, :warm, :hit, :miss] and is_integer(duration_ms) and duration_ms >= 0,
      do: GenServer.call(server, {:record_access, group, outcome, duration_ms}, 30_000)

  @doc "Acquires a lease for the given cache groups and owner."
  def acquire(groups, owner, server \\ __MODULE__)
      when is_list(groups),
      do: GenServer.call(server, {:acquire, groups, owner}, 30_000)

  @doc "Releases one lease returned by `acquire/3`."
  def release(lease, server \\ __MODULE__), do: GenServer.call(server, {:release, lease}, 30_000)

  @doc "Releases every lease held by an owner, useful from container teardown."
  def release_owner(owner, server \\ __MODULE__),
    do: GenServer.call(server, {:release_owner, owner}, 30_000)

  @doc "Purges only the named configured group, unless it is actively leased."
  def purge(name, server \\ __MODULE__), do: GenServer.call(server, {:purge, name}, 120_000)

  @doc "Returns whether a group currently has one or more active leases."
  def active?(name, server \\ __MODULE__), do: GenServer.call(server, {:active?, name}, 30_000)

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %{
      groups: Keyword.get(opts, :groups),
      gc_opts: Keyword.take(opts, [:metadata_root]),
      events?: Keyword.get(opts, :events?, true),
      interval_ms: interval_ms,
      leases: %{},
      monitors: %{}
    }

    schedule(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {result, state} = do_run(state)
    {:reply, result, state}
  end

  def handle_call({:snapshot, group}, _from, state) do
    result =
      with {:ok, snapshot} <- CacheGc.snapshot(group, state.gc_opts) do
        {:ok, %{snapshot | active_leases: lease_count(snapshot.group, state)}}
      end

    {:reply, result, state}
  end

  def handle_call(:snapshots, _from, state) do
    result =
      configured_groups(state)
      |> Enum.map(fn group ->
        case CacheGc.snapshot(group, state.gc_opts) do
          {:ok, snapshot} ->
            {:ok, %{snapshot | active_leases: lease_count(snapshot.group, state)}}

          error ->
            error
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:touch, group}, _from, state) do
    result = CacheGc.touch(group, state.gc_opts)
    if result == :ok, do: emit_touch(group)
    {:reply, result, state}
  end

  def handle_call({:record_access, name, outcome, duration_ms}, _from, state) do
    result =
      with {:ok, %CacheGroup{} = group} <- configured_group(name, state),
           :ok <- CacheGc.touch(group, state.gc_opts) do
        outcome = Atom.to_string(outcome)

        :telemetry.execute(
          [:omashiki, :cache, :access],
          %{count: 1, duration_ms: duration_ms},
          %{group: group.name, outcome: outcome}
        )

        record_event(state.events?, %{
          activity: "cache.access",
          resource: "system",
          case_id: Ecto.UUID.generate(),
          duration_ms: duration_ms,
          outcome: "ok",
          attrs: %{group: group.name, outcome: outcome}
        })

        :ok
      end

    {:reply, result, state}
  end

  def handle_call({:acquire, groups, owner}, _from, state) do
    with {:ok, resolved} <- resolve_groups(groups),
         :ok <- touch_groups(resolved, state.gc_opts) do
      lease = make_ref()
      monitor = monitor_owner(owner)

      state = %{
        state
        | leases:
            Map.put(state.leases, lease, %{
              owner: owner,
              groups: Enum.map(resolved, & &1.name),
              monitor: monitor
            }),
          monitors: put_monitor(state.monitors, monitor, lease)
      }

      Enum.each(resolved, &emit_lease("cache.lease_acquired", &1.name, state.events?))
      {:reply, {:ok, lease}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {released, state} = remove_lease(lease, state)
    Enum.each(released, &emit_lease("cache.lease_released", &1, state.events?))
    {:reply, :ok, state}
  end

  def handle_call({:release_owner, owner}, _from, state) do
    leases =
      state.leases
      |> Enum.filter(fn {_lease, data} -> data.owner == owner end)
      |> Enum.map(&elem(&1, 0))

    {released, state} =
      Enum.reduce(leases, {[], state}, fn lease, {groups, state} ->
        {lease_groups, state} = remove_lease(lease, state)
        {lease_groups ++ groups, state}
      end)

    Enum.each(released, &emit_lease("cache.lease_released", &1, state.events?))
    {:reply, :ok, state}
  end

  def handle_call({:purge, name}, _from, state) do
    with {:ok, %CacheGroup{} = group} <- configured_group(name, state),
         false <- active_name?(group.name, state),
         {:ok, result} <- CacheGc.purge(group, state.gc_opts) do
      emit_purge(group, result, state.events?)
      {:reply, {:ok, result}, state}
    else
      true -> {:reply, {:error, :active}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:active?, name}, _from, state) do
    {:reply, active_name?(name, state), state}
  end

  @impl true
  def handle_info(:maintenance, state) do
    {_result, state} = do_run(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      nil ->
        {:noreply, state}

      lease ->
        {released, state} = remove_lease(lease, state)
        Enum.each(released, &emit_lease("cache.lease_released", &1, state.events?))
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------

  defp do_run(state) do
    started = System.monotonic_time(:microsecond)
    groups = configured_groups(state)
    reports = Enum.map(groups, &maintain_group(&1, state))
    errors = Enum.count(reports, &match?({:error, _}, &1))
    duration_ms = div(System.monotonic_time(:microsecond) - started, 1_000)

    :telemetry.execute(
      [:omashiki, :cache, :maintenance],
      %{duration_ms: duration_ms, groups: length(groups), errors: errors},
      %{}
    )

    record_event(state.events?, %{
      activity: "cache.maintenance",
      resource: "system",
      case_id: Ecto.UUID.generate(),
      duration_ms: duration_ms,
      outcome: if(errors == 0, do: "ok", else: "error"),
      attrs: %{groups: length(groups), errors: errors}
    })

    {{:ok, reports}, state}
  end

  defp maintain_group(group, state) do
    protected? = active_name?(group.name, state)

    case CacheGc.enforce(group, Keyword.put(state.gc_opts, :protected?, protected?)) do
      {:ok, result} ->
        snapshot = %{result.snapshot | active_leases: lease_count(group.name, state)}
        result = Map.put(result, :snapshot, snapshot)

        :telemetry.execute([:omashiki, :cache, :snapshot], %{size_bytes: snapshot.size_bytes}, %{
          group: group.name
        })

        if result.evicted != [] do
          bytes = result.bytes_reclaimed

          :telemetry.execute(
            [:omashiki, :cache, :evicted],
            %{count: length(result.evicted), bytes: bytes},
            %{group: group.name}
          )

          record_event(state.events?, %{
            activity: "cache.evicted",
            resource: "system",
            case_id: Ecto.UUID.generate(),
            outcome: "ok",
            attrs: %{
              group: group.name,
              entries: Enum.map(result.evicted, & &1.name),
              bytes: bytes
            }
          })
        end

        {:ok, result}

      {:error, reason} = error ->
        Logger.warning("[CacheMaintenance] #{group.name} skipped: #{inspect(reason)}")
        error
    end
  end

  defp configured_groups(%{groups: groups}) when is_list(groups), do: groups
  defp configured_groups(_state), do: Omashiki.Config.caches()

  defp resolve_groups(groups) do
    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, resolved} ->
      case CacheGc.group(group) do
        {:ok, group} -> {:cont, {:ok, [group | resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, groups} -> {:ok, Enum.reverse(groups)}
      error -> error
    end)
  end

  defp configured_group(name, state) do
    case CacheGc.group(name) do
      {:ok, group} ->
        {:ok, group}

      {:error, {:unknown_group, ^name}} ->
        case Enum.find(configured_groups(state), &(&1.name == name)) do
          %CacheGroup{} = group -> {:ok, group}
          nil -> {:error, {:unknown_group, name}}
        end

      error ->
        error
    end
  end

  defp touch_groups(groups, opts) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case CacheGc.touch(group, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  defp monitor_owner(_owner), do: nil

  defp put_monitor(monitors, nil, _lease), do: monitors
  defp put_monitor(monitors, monitor, lease), do: Map.put(monitors, monitor, lease)

  defp remove_lease(lease, state) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        {[], state}

      {%{groups: groups, monitor: monitor}, leases} ->
        if monitor, do: Process.demonitor(monitor, [:flush])
        {groups, %{state | leases: leases, monitors: Map.delete(state.monitors, monitor)}}
    end
  end

  defp active_name?(name, state) do
    lease_count(name, state) > 0
  end

  defp lease_count(name, state) do
    Enum.count(state.leases, fn {_lease, data} -> name in data.groups end)
  end

  defp schedule(:infinity), do: :ok

  defp schedule(interval_ms) when is_integer(interval_ms) and interval_ms > 0,
    do: Process.send_after(self(), :maintenance, interval_ms)

  defp schedule(_), do: :ok

  defp emit_touch(group),
    do: :telemetry.execute([:omashiki, :cache, :touch], %{count: 1}, %{group: group_name(group)})

  defp emit_lease(activity, group, events?) do
    :telemetry.execute([:omashiki, :cache, :lease], %{count: 1}, %{group: group})

    record_event(events?, %{
      activity: activity,
      resource: "system",
      case_id: Ecto.UUID.generate(),
      attrs: %{group: group}
    })
  end

  defp emit_purge(group, result, events?) do
    :telemetry.execute(
      [:omashiki, :cache, :purged],
      %{count: length(result.removed), bytes: result.bytes_reclaimed},
      %{group: group.name}
    )

    record_event(events?, %{
      activity: "cache.purged",
      resource: "system",
      case_id: Ecto.UUID.generate(),
      outcome: "ok",
      attrs: %{group: group.name, entries: length(result.removed), bytes: result.bytes_reclaimed}
    })
  end

  defp record_event(true, attrs), do: Logger.debug("runtime cache event #{inspect(attrs)}")
  defp record_event(false, _attrs), do: :ok

  defp group_name(%CacheGroup{name: name}), do: name
  defp group_name(name), do: name
end
