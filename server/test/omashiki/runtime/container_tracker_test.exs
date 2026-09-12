defmodule Omashiki.Runtime.ContainerTrackerTest do
  use ExUnit.Case, async: false

  alias Omashiki.Runtime.{ContainerEvents, ContainerTracker}

  import Omashiki.Await, only: [until: 1]

  @attempt_id "7d3f7c2e-9d1a-4c55-9a51-2f7e2b3c4d5e"
  @container "a1b2c3d4e5f60718"

  setup do
    {:ok, census} = Agent.start_link(fn -> {:ok, []} end)

    tracker =
      start_supervised!(
        {ContainerTracker,
         name: nil, census: fn -> Agent.get(census, & &1) end, reconcile_ms: :timer.hours(1)}
      )

    Phoenix.PubSub.subscribe(Omashiki.PubSub, ContainerTracker.topic())
    until(fn -> :sys.get_state(tracker).task == nil end)
    flush_changes()

    {:ok, tracker: tracker, census: census}
  end

  test "lifecycle events move a container through created, running, and removed",
       %{tracker: tracker} do
    now = DateTime.utc_now()

    send(tracker, event(:created, "job-" <> @attempt_id, now))

    assert [%{id: @container, attempt_id: @attempt_id, state: "created", started_at: nil}] =
             ContainerTracker.list(tracker)

    assert_receive :containers_changed

    send(tracker, event(:started, nil, now))
    assert [%{state: "running", started_at: ^now}] = ContainerTracker.list(tracker)
    assert_receive :containers_changed

    send(tracker, event(:removed, "job-" <> @attempt_id, now))
    assert ContainerTracker.list(tracker) == []
    assert_receive :containers_changed
  end

  test "the census replaces the list and keeps start times the events recorded",
       %{tracker: tracker, census: census} do
    started = DateTime.utc_now()
    send(tracker, event(:created, "job-" <> @attempt_id, started))
    send(tracker, event(:started, nil, started))
    flush_changes()

    other = "ffffeeeedddd0000"
    created = System.os_time(:second)

    Agent.update(census, fn _ ->
      {:ok,
       [
         %{
           id: @container,
           scope_id: "job-" <> @attempt_id,
           state: "running",
           created_at: created
         },
         %{id: other, scope_id: nil, state: "exited", created_at: created}
       ]}
    end)

    ContainerTracker.reconcile(tracker)
    until(fn -> length(ContainerTracker.list(tracker)) == 2 end)

    containers = Map.new(ContainerTracker.list(tracker), &{&1.id, &1})
    assert containers[@container].started_at == started
    assert containers[other].state == "exited"
    assert containers[other].attempt_id == nil
    assert_receive :containers_changed
  end

  test "an unchanged census announces nothing", %{tracker: tracker} do
    ContainerTracker.reconcile(tracker)
    until(fn -> :sys.get_state(tracker).task == nil end)

    refute_receive :containers_changed, 100
  end

  test "ContainerManager's events reach a subscriber on this node" do
    ContainerEvents.subscribe()
    ContainerEvents.publish(:created, @container, "job-" <> @attempt_id)

    assert_receive {:container_event, %{event: :created, id: @container, scope_id: scope}}
    assert scope == "job-" <> @attempt_id
  end

  test "list is empty when no tracker runs under the name" do
    assert ContainerTracker.list(:no_such_tracker) == []
  end

  defp event(kind, scope_id, at),
    do: {:container_event, %{event: kind, id: @container, scope_id: scope_id, at: at}}

  defp flush_changes do
    receive do
      :containers_changed -> flush_changes()
    after
      50 -> :ok
    end
  end
end
