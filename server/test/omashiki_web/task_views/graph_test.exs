defmodule OmashikiWeb.TaskViews.GraphTest do
  use Omashiki.DataCase, async: false

  import Omashiki.Fixtures
  import Omashiki.JobFixtures

  alias OmashikiWeb.TaskViews
  alias OmashikiWeb.TaskViews.Graph

  setup do
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    {job, attempt} =
      job_fixture(user, token, %{
        status: "running",
        environment: "codex",
        payload: %{"instruction" => "Fix login", "title" => "fix-login"}
      })

    other = user_fixture()
    {other_token, _plaintext} = api_token_fixture(other)
    {_other_job, other_attempt} = job_fixture(other, other_token, %{status: "running"})

    now = DateTime.utc_now()

    nodes = [
      %{
        machine_id: "vps-1",
        kind: :worker,
        stale?: false,
        last_seen_at: now,
        capacity: 4,
        free_slots: 1,
        containers: [
          container("aaaaaaaaaaaa", attempt.id),
          container("bbbbbbbbbbbb", other_attempt.id),
          container("cccccccccccc", nil)
        ]
      },
      %{
        machine_id: "vps-2",
        kind: :worker,
        stale?: true,
        last_seen_at: DateTime.add(now, -120, :second),
        capacity: 2,
        free_slots: 2,
        containers: []
      }
    ]

    {:ok, user: user, job: job, nodes: nodes, now: now}
  end

  test "containers are joined to the operator's own jobs only", ctx do
    graph = Graph.build(ctx.user, view(""), ctx.now, ctx.nodes)

    assert [%{machine_id: "vps-1", containers: containers}, %{machine_id: "vps-2"}] = graph.nodes
    rows = Map.new(containers, &{&1.id, &1.row})

    assert rows["aaaaaaaaaaaa"].job.id == ctx.job.id
    assert rows["bbbbbbbbbbbb"] == nil
    assert rows["cccccccccccc"] == nil

    assert graph.counts == %{nodes: 2, live: 1, stale: 1, containers: 3, running: 3}
  end

  test "a job filter keeps only containers whose job matches", ctx do
    graph =
      Graph.build(ctx.user, view(~s(filter = { environment = "codex" }\n)), ctx.now, ctx.nodes)

    assert [%{containers: [%{id: "aaaaaaaaaaaa"}]}, %{machine_id: "vps-2", containers: []}] =
             graph.nodes
  end

  test "idle, stale, and unlisted workers can be left out", ctx do
    assert [%{machine_id: "vps-1"}] =
             Graph.build(ctx.user, view("show_idle_workers = false\n"), ctx.now, ctx.nodes).nodes

    assert [%{machine_id: "vps-1"}] =
             Graph.build(ctx.user, view("show_stale_workers = false\n"), ctx.now, ctx.nodes).nodes

    assert [%{machine_id: "vps-2"}] =
             Graph.build(ctx.user, view(~s(filter = { worker = "vps-2" }\n)), ctx.now, ctx.nodes).nodes
  end

  test "a worker going stale is noticed without an event", ctx do
    graph = Graph.build(ctx.user, view(""), ctx.now, ctx.nodes)

    refute Graph.stale_changed?(graph, [
             %{machine_id: "vps-1", stale?: false},
             %{machine_id: "vps-2", stale?: true}
           ])

    assert Graph.stale_changed?(graph, [
             %{machine_id: "vps-1", stale?: true},
             %{machine_id: "vps-2", stale?: true}
           ])
  end

  defp view(extra) do
    {:ok, [view], _default} =
      TaskViews.parse(~s([[views]]\nname = "fleet"\nlayout = "graph"\n) <> extra)

    view
  end

  defp container(id, attempt_id) do
    %{
      id: id,
      attempt_id: attempt_id,
      scope_id: nil,
      state: "running",
      created_at: nil,
      started_at: nil
    }
  end
end
