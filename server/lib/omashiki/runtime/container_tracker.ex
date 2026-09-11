defmodule Omashiki.Runtime.ContainerTracker do
  @moduledoc """
  The containers this node is running, kept current from lifecycle events.

  `ContainerEvents` says what changed the moment `ContainerManager` changed it,
  so the list moves without asking Docker. A periodic census replaces the list
  wholesale; it catches what events cannot see, such as a container removed
  outside Omashiki or events missed while this process restarted.

  Every change is published twice: on `topic/0` for this node's worker poller,
  which forwards the list to its managers, and through `Omashiki.Fleet` for an
  operator screen served by this node.
  """

  use GenServer

  require Logger

  alias Omashiki.Fleet
  alias Omashiki.Runtime.{ContainerEvents, ContainerManager}

  @topic "runtime:containers:tracked"
  @reconcile_ms 10_000

  @type container :: %{
          id: String.t(),
          scope_id: String.t() | nil,
          attempt_id: String.t() | nil,
          state: String.t(),
          created_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil
        }

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    server_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "PubSub topic carrying `:containers_changed` after the list changes."
  def topic, do: @topic

  @doc "Current containers, oldest first. Empty when the tracker is not running."
  @spec list(GenServer.server()) :: [container()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  catch
    :exit, _reason -> []
  end

  @doc "Replace the list from a census now, instead of at the next interval."
  def reconcile(server \\ __MODULE__), do: send(server, :reconcile)

  @impl true
  def init(opts) do
    ContainerEvents.subscribe()

    interval =
      Keyword.get_lazy(opts, :reconcile_ms, fn ->
        Application.get_env(:omashiki, :container_tracker_reconcile_ms, @reconcile_ms)
      end)

    send(self(), :reconcile)

    {:ok,
     %{
       containers: %{},
       census: Keyword.get(opts, :census, :configured),
       reconcile_ms: interval,
       task: nil
     }}
  end

  @impl true
  def handle_call(:list, _from, state) do
    containers = state.containers |> Map.values() |> Enum.sort_by(&sort_key/1)
    {:reply, containers, state}
  end

  @impl true
  def handle_info({:container_event, %{event: :created} = event}, state) do
    entry = entry(event.id, event.scope_id, "created", event.at, nil)
    {:noreply, put_containers(state, Map.put(state.containers, event.id, entry))}
  end

  def handle_info({:container_event, %{event: :started} = event}, state) do
    entry =
      case Map.get(state.containers, event.id) do
        nil -> entry(event.id, event.scope_id, "running", event.at, event.at)
        existing -> %{existing | state: "running", started_at: event.at}
      end

    {:noreply, put_containers(state, Map.put(state.containers, event.id, entry))}
  end

  def handle_info({:container_event, %{event: :removed} = event}, state),
    do: {:noreply, put_containers(state, Map.delete(state.containers, event.id))}

  def handle_info(:reconcile, %{task: nil} = state) do
    schedule_reconcile(state.reconcile_ms)
    census = state.census

    task =
      Task.Supervisor.async_nolink(Omashiki.Runtime.TaskSupervisor, fn -> take_census(census) end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:reconcile, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case result do
      {:ok, entries} when is_list(entries) ->
        {:noreply, put_containers(state, from_census(entries, state.containers))}

      other ->
        Logger.debug("[ContainerTracker] census skipped: #{inspect(other)}")
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | task: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  # The census is the whole truth at one instant, but it has no start times.
  # Keep the ones the events already recorded.
  defp from_census(entries, current) do
    Map.new(entries, fn census ->
      previous = Map.get(current, census.id)

      started_at =
        cond do
          previous && previous.started_at -> previous.started_at
          census.state == "running" -> unix(census.created_at)
          true -> nil
        end

      {census.id,
       entry(census.id, census.scope_id, census.state, unix(census.created_at), started_at)}
    end)
  end

  defp put_containers(%{containers: same} = state, same), do: state

  defp put_containers(state, containers) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, @topic, :containers_changed)
    Fleet.broadcast_updated(Fleet.local_machine_id())
    %{state | containers: containers}
  end

  defp entry(id, scope_id, container_state, created_at, started_at) do
    %{
      id: id,
      scope_id: scope_id,
      attempt_id: attempt_id(scope_id),
      state: container_state,
      created_at: created_at,
      started_at: started_at
    }
  end

  defp attempt_id("job-" <> attempt_id) when attempt_id != "", do: attempt_id
  defp attempt_id(_scope_id), do: nil

  defp unix(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp unix(_seconds), do: nil

  defp sort_key(%{created_at: nil, id: id}), do: {1, 0, id}
  defp sort_key(%{created_at: at, id: id}), do: {0, DateTime.to_unix(at, :microsecond), id}

  defp take_census(:configured) do
    {module, function, args} =
      Application.get_env(:omashiki, :runtime_census, {ContainerManager, :census, []})

    apply(module, function, args)
  end

  defp take_census(fun) when is_function(fun, 0), do: fun.()

  defp schedule_reconcile(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :reconcile, interval)

  defp schedule_reconcile(_interval), do: :ok
end
