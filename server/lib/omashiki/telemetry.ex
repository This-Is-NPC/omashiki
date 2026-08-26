defmodule Omashiki.Telemetry do
  @moduledoc """
  The inventory of `:telemetry` events this application emits, and the
  supervisor for the handler attached to them.

  Every event below used to be emitted into nothing: `:telemetry.execute/3` with
  no handler is a function call that builds a map and returns `:ok`. Thirteen of
  them accumulated that way — step durations, container provisioning, cache
  maintenance — so the cost of measuring was paid and the measurement was thrown
  away.

  Two consumers now exist, and they answer different questions:

    * `Omashiki.Telemetry.Recorder` is always on. It keeps a count and a
      last-seen time per `{event, outcome}`, which is what tells an operator
      whether anything is still making progress.

    * `metrics/0` feeds LiveDashboard's Metrics page, which attaches its own
      handlers while a browser has it open and shows distributions rather than
      totals.

  `events/0` is the contract: `Omashiki.TelemetryTest` scans `lib/` for literal
  `:telemetry.execute/3` calls and fails when one is missing from it, so a new
  event cannot be added without deciding who listens.
  """

  use Supervisor

  import Telemetry.Metrics

  @doc false
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Supervisor.init([Omashiki.Telemetry.Recorder], strategy: :one_for_one)
  end

  # The `[:omashiki, :runtime, :attempt, _]` names are built from a variable in
  # Omashiki.Runtime.Attempt, so the source scan in the test cannot see them.
  # They are covered there by emitting each one for real instead.
  @events [
    [:omashiki, :runtime, :attempt, :cancel],
    [:omashiki, :runtime, :attempt, :heartbeat],
    [:omashiki, :runtime, :attempt, :complete],
    [:omashiki, :runtime, :step],
    [:omashiki, :container, :provision],
    [:omashiki, :container, :bootstrap],
    [:omashiki, :cache, :access],
    [:omashiki, :cache, :maintenance],
    [:omashiki, :cache, :snapshot],
    [:omashiki, :cache, :evicted],
    [:omashiki, :cache, :purged],
    [:omashiki, :cache, :touch],
    [:omashiki, :cache, :lease]
  ]

  @doc "Every event name emitted by this application. The recorder attaches to exactly this list."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc """
  `Telemetry.Metrics` definitions for LiveDashboard's Metrics page.

  A superset of `events/0`: the `:telemetry_poller` application ships a default
  poller that emits the `[:vm, _]` events whether or not anything reports them,
  so they are included rather than left as a second set of measurements nobody
  reads.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    runtime_metrics() ++ container_metrics() ++ cache_metrics() ++ vm_metrics()
  end

  defp runtime_metrics do
    [
      summary("omashiki.runtime.step.duration_ms",
        unit: :millisecond,
        tags: [:kind, :outcome],
        description: "Wall time of one runner step, from the monotonic clock."
      ),
      summary("omashiki.runtime.attempt.complete.duration_ms",
        unit: :millisecond,
        tags: [:outcome],
        description: "Lifetime of an attempt coordinator, start to terminal result."
      ),
      counter("omashiki.runtime.attempt.cancel.count",
        tags: [:outcome],
        description: "Cancellations requested against a running attempt."
      ),
      counter("omashiki.runtime.attempt.heartbeat.count",
        tags: [:outcome],
        description: "Heartbeats that failed or lost their lease. Healthy ticks do not emit."
      )
    ]
  end

  defp container_metrics do
    [
      summary("omashiki.container.provision.duration_ms",
        unit: :millisecond,
        tags: [:outcome],
        description: "Time to create and start one agent container."
      ),
      summary("omashiki.container.bootstrap.duration_ms",
        unit: :millisecond,
        tags: [:outcome],
        description: "Time spent running the environment's pre_steps inside the container."
      )
    ]
  end

  defp cache_metrics do
    [
      counter("omashiki.cache.access.count", tags: [:group, :outcome]),
      summary("omashiki.cache.access.duration_ms", unit: :millisecond, tags: [:group, :outcome]),
      summary("omashiki.cache.maintenance.duration_ms", unit: :millisecond),
      last_value("omashiki.cache.maintenance.errors"),
      last_value("omashiki.cache.snapshot.size_bytes", unit: :byte, tags: [:group]),
      counter("omashiki.cache.evicted.count", tags: [:group]),
      counter("omashiki.cache.purged.count", tags: [:group]),
      counter("omashiki.cache.touch.count", tags: [:group]),
      counter("omashiki.cache.lease.count", tags: [:group])
    ]
  end

  defp vm_metrics do
    [
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count")
    ]
  end
end
