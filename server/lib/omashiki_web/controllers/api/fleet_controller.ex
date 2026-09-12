defmodule OmashikiWeb.Api.FleetController do
  use OmashikiWeb.Api.Controller

  alias Omashiki.Fleet
  alias Omashiki.Jobs.Api
  alias OmashikiWeb.Api.Conn, as: ApiConn
  alias OmashikiWeb.ApiSpec.Schemas

  tags(["fleet"])

  operation(:index,
    summary: "List worker nodes and containers",
    security: [%{"bearer" => ["read"]}],
    responses: %{200 => {"Fleet", "application/json", Schemas.FleetResponse}}
  )

  def index(conn, _params) do
    nodes = Fleet.nodes()

    attempt_ids =
      nodes
      |> Enum.flat_map(& &1.containers)
      |> Enum.map(& &1.attempt_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    jobs = Api.job_ids_for_attempts(ApiConn.actor(conn), attempt_ids)

    json(conn, %{data: Enum.map(nodes, &node_json(&1, jobs))})
  end

  defp node_json(node, jobs) do
    %{
      machine_id: node.machine_id,
      kind: node.kind,
      stale: node.stale?,
      last_seen_at: node.last_seen_at,
      capacity: node.capacity,
      free_slots: node.free_slots,
      containers: Enum.map(node.containers, &container_json(&1, jobs))
    }
  end

  defp container_json(container, jobs) do
    %{
      id: container.id,
      state: container.state,
      created_at: container.created_at,
      started_at: container.started_at,
      job_id: Map.get(jobs, container.attempt_id)
    }
  end
end
