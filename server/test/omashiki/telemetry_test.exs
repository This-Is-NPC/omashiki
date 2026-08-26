defmodule Omashiki.TelemetryTest do
  @moduledoc """
  The application emitted thirteen `:telemetry` events and attached nothing to
  any of them, so every one was measured and discarded. These tests pin both
  halves of the fix: the inventory has to stay complete as events are added,
  and something has to actually be listening to it.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Telemetry
  alias Omashiki.Telemetry.Recorder

  describe "the inventory is complete" do
    test "every event emitted from lib/ is declared in events/0" do
      undeclared = emitted_events() -- Telemetry.events()

      assert undeclared == [],
             "these events are emitted but not declared in Omashiki.Telemetry.events/0, " <>
               "so nothing is attached to them:\n  " <>
               Enum.map_join(undeclared, "\n  ", &inspect/1)
    end

    test "the source scanner actually finds events" do
      # Guards the check above from rotting into a no-op: if the scanner stops
      # matching, this fails before the real assertion goes quiet.
      assert [:omashiki, :runtime, :step] in emitted_events()
      assert [:omashiki, :container, :provision] in emitted_events()
      assert length(emitted_events()) >= 10
    end

    test "every declared event has at least one attached handler" do
      unattached = Enum.filter(Telemetry.events(), &(:telemetry.list_handlers(&1) == []))

      assert unattached == [],
             "these events are declared but nothing is attached, so they are still " <>
               "emitted into the void:\n  " <>
               Enum.map_join(unattached, "\n  ", &inspect/1)
    end

    test "every declared event is reported by at least one metric" do
      metric_events = MapSet.new(Telemetry.metrics(), & &1.event_name)

      uncovered = Enum.reject(Telemetry.events(), &MapSet.member?(metric_events, &1))

      assert uncovered == [],
             "these events have no Telemetry.Metrics definition, so the dashboard's " <>
               "Metrics page cannot show them:\n  " <>
               Enum.map_join(uncovered, "\n  ", &inspect/1)
    end
  end

  describe "the recorder counts what is emitted" do
    # The three attempt events are built as `[:omashiki, :runtime, :attempt,
    # event]` with `event` a variable, so no source scan can find them. Emitting
    # each for real is the only check that covers them.
    test "the dynamic attempt events land in the recorder" do
      for event <- [:cancel, :heartbeat, :complete] do
        name = [:omashiki, :runtime, :attempt, event]
        before = count_for(name, "ok")

        :telemetry.execute(name, %{count: 1, duration_ms: 3}, %{
          attempt_id: "t",
          outcome: "ok"
        })

        assert count_for(name, "ok") == before + 1,
               "#{inspect(name)} was emitted but the recorder did not count it"
      end
    end

    test "outcomes are counted apart, so a wedge shows as errors without successes" do
      name = [:omashiki, :container, :provision]
      ok_before = count_for(name, "ok")
      error_before = count_for(name, "error")

      :telemetry.execute(name, %{duration_ms: 1}, %{outcome: "error"})

      assert count_for(name, "ok") == ok_before
      assert count_for(name, "error") == error_before + 1
    end

    test "an event with no outcome in its metadata is still counted" do
      name = [:omashiki, :cache, :snapshot]
      before = count_for(name, "none")

      :telemetry.execute(name, %{size_bytes: 10}, %{group: "global"})

      assert count_for(name, "none") == before + 1
    end
  end

  defp count_for(event, outcome) do
    case Enum.find(Recorder.snapshot(), &(&1.event == event and &1.outcome == outcome)) do
      nil -> 0
      row -> row.count
    end
  end

  # Every fully literal `:telemetry.execute([...])` event name under lib/.
  # Lists containing a variable (the attempt events) cannot be read this way and
  # are covered by the emission tests above instead.
  defp emitted_events do
    Path.wildcard("lib/**/*.ex")
    |> Enum.flat_map(fn path -> path |> File.read!() |> scan_events() end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scan_events(source) do
    ~r/:telemetry\.execute\(\s*\[([^\]]+)\]/s
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [inner] -> inner |> String.split(",") |> Enum.map(&String.trim/1) end)
    |> Enum.filter(fn parts -> Enum.all?(parts, &String.starts_with?(&1, ":")) end)
    |> Enum.map(fn parts ->
      Enum.map(parts, &String.to_atom(String.trim_leading(&1, ":")))
    end)
  end
end
