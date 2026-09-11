defmodule Omashiki.Worker.PresenceTest do
  use ExUnit.Case, async: false

  alias Omashiki.Worker.Presence

  setup do
    Presence.reset()
    on_exit(fn -> Presence.reset() end)
  end

  # Polls arrive in short-lived request processes. The table belongs to the
  # application, so a poll outlives the process that recorded it.
  test "a poll recorded by a process that exits is still listed" do
    Task.async(fn -> Presence.touch("vps-short-lived", %{free_slots: 2}) end)
    |> Task.await()

    assert [%{machine_id: "vps-short-lived", free_slots: 2, stale?: false}] = Presence.list()
  end
end
