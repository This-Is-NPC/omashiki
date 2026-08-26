defmodule OmashikiWeb.OverviewLiveTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Omashiki.Jobs.ExecutionCapacity
  alias Omashiki.Repo

  # The ceiling an operator reads has to be the cluster's, not the one machine's
  # `[limits].max_concurrent_containers` that happens to be serving the console.
  # Those two numbers are equal on a single-node install and differ by every
  # other node once there is a cluster, which is exactly when the number is being
  # read to decide whether the queue is starved.
  test "runtime capacity totals every node's row, not this host's limit", %{conn: conn} do
    Repo.delete_all(ExecutionCapacity)
    insert_node!("node-a", 10)
    insert_node!("node-b", 6)

    {:ok, _lv, html} = live(conn, ~p"/")
    text = visible_text(html)

    assert text =~ "0 / 16"
    assert text =~ "16 free"
  end

  test "runtime capacity is zero when no node has booted", %{conn: conn} do
    Repo.delete_all(ExecutionCapacity)

    {:ok, _lv, html} = live(conn, ~p"/")
    assert visible_text(html) =~ "0 / 0"
  end

  defp insert_node!(node, capacity) do
    now = DateTime.utc_now()

    Repo.insert!(%ExecutionCapacity{
      node_id: node,
      capacity: capacity,
      active: 0,
      inserted_at: now,
      updated_at: now
    })
  end
end
