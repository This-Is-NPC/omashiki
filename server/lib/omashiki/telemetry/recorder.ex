defmodule Omashiki.Telemetry.Recorder do
  @moduledoc """
  The always-on handler for `Omashiki.Telemetry.events/0`.

  LiveDashboard's Metrics page attaches handlers too, but only while a browser
  has that page open, so on its own it observes nothing exactly when nobody is
  watching — which is when the interesting events fire. This keeps a count, a
  summed duration and a last-seen time per `{event, outcome}` in ETS.

  Totals, not distributions. The question this exists to answer is the one that
  went unanswerable for seventeen minutes during a resilience run: *is anything
  still finishing?* "`container.provision` last seen 14 minutes ago, 0 completes
  since" is that answer, and it does not need a histogram.

  The handler runs inline in whichever process emitted the event, so it is two
  ETS writes and nothing else, and it is written not to raise: `:telemetry`
  silently detaches a handler that throws, which would take the other twelve
  events down with it.
  """

  use GenServer

  @table :omashiki_telemetry_counters
  @handler_id {__MODULE__, :counters}

  @type entry :: %{
          event: [atom()],
          outcome: String.t(),
          count: non_neg_integer(),
          total_ms: non_neg_integer(),
          last_seen_ms: non_neg_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every observed `{event, outcome}` pair, most recently seen first."
  @spec snapshot() :: [entry()]
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{event, outcome}, count, total_ms, last_seen_ms} ->
      %{
        event: event,
        outcome: outcome,
        count: count,
        total_ms: total_ms,
        last_seen_ms: last_seen_ms
      }
    end)
    |> Enum.sort_by(& &1.last_seen_ms, :desc)
  rescue
    ArgumentError -> []
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    table = Keyword.get(opts, :table, @table)

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, write_concurrency: true])
    end

    events = Keyword.get(opts, :events, Omashiki.Telemetry.events())
    :ok = :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)

    {:ok, %{events: events}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    key = {event, outcome(metadata)}
    duration = duration_ms(measurements)

    :ets.update_counter(@table, key, [{2, 1}, {3, duration}], {key, 0, 0, 0})
    :ets.update_element(@table, key, {4, System.system_time(:millisecond)})

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # `[:omashiki, :cache, :snapshot]` and friends carry no outcome. Bucketing
  # them under "none" keeps one shape for the whole table rather than a second
  # nil-shaped row the reader has to special-case.
  defp outcome(%{outcome: outcome}) when is_binary(outcome), do: outcome

  defp outcome(%{outcome: outcome}) when is_atom(outcome) and not is_nil(outcome),
    do: Atom.to_string(outcome)

  defp outcome(_metadata), do: "none"

  defp duration_ms(%{duration_ms: value}) when is_integer(value) and value >= 0, do: value
  defp duration_ms(_measurements), do: 0
end
