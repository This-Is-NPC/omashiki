defmodule OmashikiWeb.TaskViews.Graph do
  @moduledoc """
  The fleet graph of a view: the nodes that run this house's jobs and the
  containers on each, joined to the operator's jobs. Reads only.

  A container whose job belongs to another operator, or to no attempt at all,
  is still drawn, but only by its short id: the graph shows that it exists,
  not what it runs.
  """

  alias Omashiki.Fleet
  alias Omashiki.Jobs.Api
  alias OmashikiWeb.TaskViews.{Rows, View}

  @job_filters [:status, :environment, :repository, :priority, :since]
  @max_rows 500

  @doc "Build the graph of `view` at `now`. `nodes` defaults to `Omashiki.Fleet.nodes/1`."
  def build(user, %View{} = view, %DateTime{} = now, nodes \\ nil) do
    nodes = Enum.filter(nodes || Fleet.nodes(now), &visible?(&1, view))
    job_filter = view.filter |> Map.take(@job_filters) |> Rows.resolve_filter(now)
    rows = rows_by_attempt(user, nodes, job_filter)

    nodes =
      nodes
      |> Enum.map(&attach_rows(&1, rows, job_filter))
      |> Enum.reject(&(not view.show_idle_workers and &1.containers == []))

    %{nodes: nodes, counts: counts(nodes)}
  end

  @doc """
  True when a worker drawn in `graph` changed liveness in `presence`. Going
  stale publishes nothing, so the screen's clock asks this instead.
  """
  def stale_changed?(%{nodes: nodes}, presence) do
    stale = Map.new(presence, &{&1.machine_id, &1.stale?})
    Enum.any?(nodes, &(&1.kind == :worker and Map.get(stale, &1.machine_id, true) != &1.stale?))
  end

  defp visible?(node, view) do
    workers = Map.get(view.filter, :worker)

    (is_nil(workers) or node.machine_id in workers) and
      (view.show_stale_workers or not node.stale?)
  end

  defp rows_by_attempt(user, nodes, job_filter) do
    attempt_ids =
      nodes
      |> Enum.flat_map(& &1.containers)
      |> Enum.map(& &1.attempt_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if attempt_ids == [] do
      %{}
    else
      user
      |> Api.list_for_view(
        filter: Map.put(job_filter, :attempt_ids, attempt_ids),
        limit: @max_rows
      )
      |> Map.new(&{&1.attempt.id, &1})
    end
  end

  # With a job filter, a container is drawn only when its job matches; without
  # one, a container with no visible job is still part of the fleet.
  defp attach_rows(node, rows, job_filter) do
    containers =
      node.containers
      |> Enum.map(&Map.put(&1, :row, &1.attempt_id && Map.get(rows, &1.attempt_id)))
      |> Enum.reject(&(job_filter != %{} and is_nil(&1.row)))

    %{node | containers: containers}
  end

  defp counts(nodes) do
    containers = Enum.flat_map(nodes, & &1.containers)

    %{
      nodes: length(nodes),
      live: Enum.count(nodes, &(not &1.stale?)),
      stale: Enum.count(nodes, & &1.stale?),
      containers: length(containers),
      running: Enum.count(containers, &(&1.state == "running"))
    }
  end
end
