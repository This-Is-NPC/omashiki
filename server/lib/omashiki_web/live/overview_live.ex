defmodule OmashikiWeb.OverviewLive do
  @moduledoc "Operator health overview."

  use OmashikiWeb, :live_view

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.Api
  alias Omashiki.Runtimes.CacheMaintenance
  alias OmashikiWeb.OperationHelpers, as: Ops

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Omashiki.PubSub, "jobs")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Home")
     |> assign(:active_tab, :home)
     |> assign_snapshot()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_snapshot(socket)}
  end

  def handle_info({:job_updated, _job_id}, socket), do: {:noreply, assign_snapshot(socket)}
  def handle_info({:job_event, _event}, socket), do: {:noreply, assign_snapshot(socket)}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp assign_snapshot(socket) do
    user = socket.assigns.current_user
    jobs = Api.list_for_operator(user, limit: 100)
    slots = safe_slots(jobs)
    cache = cache_summary()

    socket
    |> assign(:slots, slots)
    |> assign(:queued, Enum.count(jobs, &(&1.status == "queued")))
    |> assign(:blocked, Enum.count(jobs, &(&1.status == "blocked")))
    |> assign(:running, Enum.count(jobs, &(&1.status in ["provisioning", "running"])))
    |> assign(:terminal_events, Api.recent_terminal_events(user))
    |> assign(:webhook_failures, Api.recent_webhook_failures(user))
    |> assign(:cache, cache)
  end

  # The ceiling is the sum of every node's capacity row, not this host's
  # `[limits].max_concurrent_containers`. That number describes the machine the
  # operator happens to have the console open on and says nothing about the rest
  # of the cluster; on a two-node deployment it under-reports the queue's real
  # ceiling by half, which is exactly the number an operator reads to decide
  # whether the queue is saturated or starved.
  defp safe_slots(jobs) do
    capacity = Jobs.cluster_capacity().capacity
    in_use = Enum.count(jobs, &(&1.status in ["provisioning", "running"]))
    %{capacity: capacity, in_use: in_use, free: max(capacity - in_use, 0), waiting: 0}
  rescue
    _ -> %{capacity: 0, in_use: 0, free: 0, waiting: 0}
  end

  defp cache_summary do
    groups = Config.caches()

    snapshots =
      try do
        CacheMaintenance.snapshots()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    successful = for {:ok, snapshot} <- snapshots, do: snapshot

    %{
      groups: length(groups),
      bytes: Enum.sum(Enum.map(successful, & &1.size_bytes)),
      leases: Enum.sum(Enum.map(successful, & &1.active_leases)),
      healthy: length(successful) == length(groups) and Enum.all?(successful, &(&1.errors == []))
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="font-headline italic text-3xl text-on-surface">Operations overview</h1>
          <p class="mt-1 font-mono text-sm text-on-surface-variant">
            Queue health and runtime signals
          </p>
        </div>
        <span class="font-mono text-xs text-on-surface-variant">updates every 2s</span>
      </header>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.metric
          label="SLOTS"
          value={"#{@slots.in_use} / #{@slots.capacity}"}
          note={"#{@slots.free} free · #{@slots.waiting} waiting"}
        />
        <.metric label="ACTIVE CONTAINERS" value={@running} note="provisioning + running jobs" />
        <.metric label="QUEUED" value={@queued} note={"#{@blocked} blocked"} />
        <.metric
          label="CACHE"
          value={if @cache.healthy, do: "healthy", else: "degraded"}
          note={"#{@cache.groups} groups · #{@cache.leases} leases"}
          value_class={if @cache.healthy, do: "text-status-succeeded", else: "text-status-failed"}
        />
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <.panel title="Cache health" meta={"#{@cache.groups} configured"}>
          <div class="flex items-center justify-between gap-4">
            <span class={[
              "font-headline italic text-2xl",
              if(@cache.healthy, do: "text-status-succeeded", else: "text-status-failed")
            ]}>
              {if @cache.healthy, do: "Ready", else: "Attention required"}
            </span>
            <span class="font-mono text-sm text-on-surface-variant">{format_bytes(@cache.bytes)}</span>
          </div>
          <p class="font-mono text-xs text-on-surface-variant">
            Mounted payload paths stay hidden from the operator surface.
          </p>
        </.panel>

        <.panel title="Recent terminal events" meta="durable job events">
          <ul :if={@terminal_events != []} class="divide-y divide-outline-variant/40">
            <li
              :for={event <- @terminal_events}
              class="flex flex-wrap items-baseline justify-between gap-3 py-3"
            >
              <span class="font-mono text-xs text-on-surface">{Ops.short_id(event.job_id)}</span>
              <span class={["font-mono text-xs uppercase", Ops.status_class(event.status)]}>{event.status}</span>
              <time class="font-mono text-xs text-on-surface-variant" datetime={event.occurred_at}>{Ops.age(
                event.occurred_at
              )} ago</time>
            </li>
          </ul>
          <p :if={@terminal_events == []} class="font-mono text-xs text-on-surface-variant">
            No terminal events recorded.
          </p>
        </.panel>

        <.panel title="Webhook failures" meta="failed and dead-lettered deliveries">
          <ul :if={@webhook_failures != []} class="divide-y divide-outline-variant/40">
            <li
              :for={delivery <- @webhook_failures}
              class="flex flex-wrap items-baseline justify-between gap-3 py-3"
            >
              <span class="font-mono text-xs text-on-surface">{Ops.short_id(delivery.job_id)}</span>
              <span class={["font-mono text-xs uppercase", Ops.status_class(delivery.status)]}>{delivery.status}</span>
              <span class="font-mono text-xs text-on-surface-variant">attempt {delivery.attempts}</span>
            </li>
          </ul>
          <p :if={@webhook_failures == []} class="font-mono text-xs text-on-surface-variant">
            No webhook failures.
          </p>
        </.panel>

        <.panel title="Runtime capacity" meta="summed across nodes">
          <dl class="grid grid-cols-2 gap-x-4 gap-y-3 font-mono text-xs">
            <dt class="text-on-surface-variant">cluster limit</dt><dd class="text-right text-on-surface">
              {@slots.capacity}
            </dd>
            <dt class="text-on-surface-variant">active</dt><dd class="text-right text-on-surface">
              {@slots.in_use}
            </dd>
            <dt class="text-on-surface-variant">free</dt><dd class="text-right text-on-surface">
              {@slots.free}
            </dd>
            <dt class="text-on-surface-variant">waiting</dt><dd class="text-right text-on-surface">
              {@slots.waiting}
            </dd>
          </dl>
        </.panel>
      </div>
    </div>
    """
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "—"

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, required: true
  attr :value_class, :string, default: "text-on-surface"

  defp metric(assigns) do
    ~H"""
    <section class="border border-outline-variant bg-surface-container p-5">
      <p class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
        {@label}
      </p>
      <p class={["mt-3 font-headline italic text-3xl tabular-nums", @value_class]}>{@value}</p>
      <p class="mt-1 font-mono text-xs text-on-surface-variant">{@note}</p>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :meta, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section class="border border-outline-variant bg-surface-container p-5">
      <header class="mb-4 flex flex-wrap items-baseline justify-between gap-3">
        <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
          {@title}
        </h2>
        <span class="font-mono text-xs text-on-surface-variant">{@meta}</span>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
