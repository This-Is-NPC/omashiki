defmodule Omashiki.Fleet do
  @moduledoc """
  The machines that run this house's jobs, and the containers on each.

  Remote workers report to the manager through `POST /internal/work/report`,
  recorded by `Omashiki.Worker.Presence`. A node that runs jobs itself
  (embedded role) reads its own `Omashiki.Runtime.ContainerTracker`. Both end up
  in the same shape, so a screen draws one graph whatever the topology.

  `topic/0` carries `{:fleet_updated, machine_id}` whenever a node appears,
  changes its slots, or starts or removes a container. PubSub is not clustered
  across nodes, so each node only announces what it recorded itself.
  """

  alias Omashiki.Config
  alias Omashiki.Jobs.ExecutionCapacity
  alias Omashiki.Repo
  alias Omashiki.Runtime.ContainerTracker
  alias Omashiki.Worker.Presence

  @topic "fleet"
  @container_states ~w(created running paused restarting removing exited dead)
  @max_containers 200
  @container_id ~r/^[a-f0-9]{12,64}$/

  @type fleet_node :: %{
          machine_id: String.t(),
          kind: :local | :worker,
          stale?: boolean(),
          last_seen_at: DateTime.t() | nil,
          capacity: non_neg_integer() | nil,
          free_slots: non_neg_integer() | nil,
          containers: [ContainerTracker.container()]
        }

  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Omashiki.PubSub, @topic)

  def broadcast_updated(machine_id) when is_binary(machine_id) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, @topic, {:fleet_updated, machine_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def broadcast_updated(_machine_id), do: :ok

  @doc "This node's machine id: the declared node, `OMASHIKI_NODE`, or the hostname."
  def local_machine_id do
    Config.current_machine().name
  rescue
    _ -> System.get_env("OMASHIKI_NODE") || hostname()
  end

  @doc "Every node that runs jobs for this house, this node first when it runs jobs."
  @spec nodes(DateTime.t()) :: [fleet_node()]
  def nodes(now \\ DateTime.utc_now()) do
    local = local_node(now)
    local_id = local && local.machine_id

    remote =
      now
      |> Presence.list()
      |> Enum.reject(&(&1.machine_id == local_id))
      |> Enum.map(&remote_node/1)

    List.wrap(local) ++ remote
  end

  defp local_node(now) do
    if Process.whereis(ContainerTracker) do
      machine_id = local_machine_id()
      {capacity, active} = local_capacity(machine_id)

      %{
        machine_id: machine_id,
        kind: :local,
        stale?: false,
        last_seen_at: now,
        capacity: capacity,
        free_slots: capacity && max(capacity - active, 0),
        containers: ContainerTracker.list()
      }
    end
  end

  defp local_capacity(machine_id) do
    case Repo.get_by(ExecutionCapacity, machine_id: machine_id) do
      %ExecutionCapacity{capacity: capacity, active: active} -> {capacity, active}
      nil -> {nil, 0}
    end
  rescue
    _ -> {nil, 0}
  end

  defp remote_node(entry) do
    %{
      machine_id: entry.machine_id,
      kind: :worker,
      stale?: entry.stale?,
      last_seen_at: entry.last_poll_at,
      capacity: Map.get(entry, :capacity),
      free_slots: entry.free_slots,
      containers: Map.get(entry, :containers, [])
    }
  end

  @doc "Wire form of one tracked container, as a worker reports it."
  def encode_container(container) do
    %{
      "id" => container.id,
      "attempt_id" => container.attempt_id,
      "state" => container.state,
      "created_at" => iso8601(container.created_at),
      "started_at" => iso8601(container.started_at)
    }
  end

  @doc """
  Validate a worker's reported containers. The report crosses a trust
  boundary, so every field is checked and nothing else is kept.
  """
  def parse_containers(nil), do: {:ok, []}

  def parse_containers(items) when is_list(items) and length(items) <= @max_containers do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parse_container(item) do
        {:ok, container} -> {:cont, {:ok, [container | acc]}}
        :error -> {:halt, {:error, :invalid_containers}}
      end
    end)
    |> case do
      {:ok, containers} -> {:ok, Enum.reverse(containers)}
      error -> error
    end
  end

  def parse_containers(_items), do: {:error, :invalid_containers}

  defp parse_container(%{"id" => id, "state" => container_state} = item)
       when is_binary(id) and container_state in @container_states do
    with true <- Regex.match?(@container_id, id),
         {:ok, attempt_id} <- optional_uuid(item["attempt_id"]),
         {:ok, created_at} <- optional_datetime(item["created_at"]),
         {:ok, started_at} <- optional_datetime(item["started_at"]) do
      {:ok,
       %{
         id: id,
         scope_id: attempt_id && "job-" <> attempt_id,
         attempt_id: attempt_id,
         state: container_state,
         created_at: created_at,
         started_at: started_at
       }}
    else
      _ -> :error
    end
  end

  defp parse_container(_item), do: :error

  defp optional_uuid(nil), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp optional_uuid(_value), do: :error

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp optional_datetime(_value), do: :error

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "local"
    end
  end
end
