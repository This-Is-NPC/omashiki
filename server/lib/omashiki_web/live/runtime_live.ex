defmodule OmashikiWeb.RuntimeLive do
  @moduledoc """
  The runtime graph: supervisor → attempt process → container → job, per node.

  Scoped deliberately to the runtime domain. A general-purpose process viewer
  already exists at `/dashboard`, and it is better at that job than anything
  written here would be. What it cannot do is the join: it sees processes and
  knows nothing about containers or attempt rows, so the state that has actually
  bitten this project — a container nothing owns, an attempt nothing is running
  — is invisible from there.

  Data comes from `Omashiki.Runtime.Inspector`, which polls once per interval
  for the whole application. Nothing on this page reaches the Docker daemon;
  render reads a cached snapshot and the snapshot's age is on the screen so a
  stalled poller cannot be mistaken for a quiet system.
  """

  use OmashikiWeb, :live_view

  alias Omashiki.Runtime.Inspector
  alias Omashiki.Telemetry.Recorder
  alias OmashikiWeb.OperationHelpers, as: Ops

  @impl true
  def mount(_params, _session, socket) do
    snapshot =
      if connected?(socket) do
        Inspector.watch()
        Inspector.refresh()
      else
        Inspector.snapshot()
      end

    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Runtime")
     |> assign(:active_tab, :runtime)
     |> assign(:snapshot, snapshot)
     |> assign(:telemetry, telemetry_rows())}
  end

  @impl true
  def handle_info({:runtime_snapshot, snapshot}, socket) do
    {:noreply, socket |> assign(:snapshot, snapshot) |> assign(:telemetry, telemetry_rows())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp telemetry_rows, do: Recorder.snapshot() |> Enum.take(8)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="font-headline italic text-3xl text-on-surface">Runtime graph</h1>
          <p class="mt-1 font-mono text-sm text-on-surface-variant">
            Attempt processes joined to the containers they own
          </p>
        </div>
        <div class="text-right">
          <p class="font-mono text-xs text-on-surface-variant">node {@snapshot.node_id || "—"}</p>
          <p class="font-mono text-xs text-on-surface-variant">{census_age(@snapshot)}</p>
        </div>
      </header>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.metric
          label="LINKED"
          value={@snapshot.counts.linked}
          note="process and container agree"
        />
        <.metric
          label="ORPHAN CONTAINERS"
          value={@snapshot.counts.orphan_container}
          note="running with no owning process"
          value_class={
            if @snapshot.counts.orphan_container > 0,
              do: "text-status-failed",
              else: "text-on-surface"
          }
        />
        <.metric
          label="NO CONTAINER"
          value={@snapshot.counts.process_without_container}
          note="process holding nothing yet"
        />
        <.metric
          label="STRANDED ATTEMPTS"
          value={@snapshot.counts.attempt_without_process}
          note="claimed here, nothing running"
          value_class={
            if @snapshot.counts.attempt_without_process > 0,
              do: "text-status-failed",
              else: "text-on-surface"
          }
        />
      </div>

      <.panel title="Supervision" meta={"node #{@snapshot.node_id || "—"}"}>
        <dl class="grid grid-cols-2 gap-x-4 gap-y-3 font-mono text-xs sm:grid-cols-4">
          <div>
            <dt class="text-on-surface-variant">AttemptSupervisor</dt>
            <dd class="text-on-surface">{@snapshot.supervised} children</dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">LeaseRenewer</dt>
            <dd class={
              if @snapshot.lease_renewer_alive?,
                do: "text-status-succeeded",
                else: "text-status-failed"
            }>
              {if @snapshot.lease_renewer_alive?, do: "alive", else: "down"}
            </dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Container runtime</dt>
            <dd class={
              if runtime_ok?(@snapshot), do: "text-status-succeeded", else: "text-status-failed"
            }>
              {runtime_label(@snapshot)}
            </dd>
          </div>
          <%!--
            Sixty-five dispatch workers reporting "executing" against zero active
            attempts is the shape of the wedge this page was built for. The two
            numbers only mean something next to each other.
          --%>
          <div>
            <dt class="text-on-surface-variant">Dispatch executing</dt>
            <dd class="text-on-surface">{@snapshot.dispatch_executing}</dd>
          </div>
        </dl>
      </.panel>

      <.panel title="Attempt processes and containers" meta={"#{length(@snapshot.rows)} tracked"}>
        <%!--
          An unreachable daemon and an idle host both produce zero rows. Saying
          "nothing is running" for the first would be the console reporting all
          clear at the exact moment it has stopped being able to see.
        --%>
        <p :if={@snapshot.rows == []} class="font-mono text-xs text-on-surface-variant">
          {empty_reason(@snapshot)}
        </p>

        <ul :if={@snapshot.rows != []} class="divide-y divide-outline-variant/40">
          <li :for={row <- @snapshot.rows} class="py-3">
            <div class="flex flex-wrap items-baseline justify-between gap-3">
              <span class="font-mono text-xs text-on-surface">
                attempt {Ops.short_id(row.attempt_id)}
              </span>
              <span class={[
                "font-label text-label-md uppercase tracking-[0.2em]",
                link_class(row.link)
              ]}>
                {link_label(row.link)}
              </span>
              <span class="font-mono text-xs text-on-surface-variant">
                {node_label(row)}
              </span>
            </div>

            <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 pl-4 font-mono text-xs sm:grid-cols-4">
              <div>
                <dt class="text-on-surface-variant">job</dt>
                <dd>
                  <.link
                    :if={row.job_id}
                    navigate={~p"/jobs/#{row.job_id}"}
                    class="text-primary-container hover:underline"
                  >{Ops.short_id(row.job_id)}</.link>
                  <span :if={is_nil(row.job_id)} class="text-on-surface-variant">no attempt row</span>
                </dd>
              </div>
              <div>
                <dt class="text-on-surface-variant">status</dt>
                <dd class={Ops.status_class(row.status)}>{Ops.status_label(row.status)}</dd>
              </div>
              <div>
                <dt class="text-on-surface-variant">process</dt>
                <dd class="text-on-surface">{process_label(row.pid)}</dd>
              </div>
              <div>
                <dt class="text-on-surface-variant">age</dt>
                <dd class="text-on-surface">{Ops.age(row.started_at)}</dd>
              </div>
            </dl>

            <ul :if={row.containers != []} class="mt-2 pl-4">
              <li
                :for={entry <- row.containers}
                class="flex flex-wrap items-baseline gap-3 font-mono text-xs text-on-surface-variant"
              >
                <span class="text-on-surface">container {short_container(entry.id)}</span>
                <span class={Ops.status_class(entry.state)}>{entry.state}</span>
                <span>{entry.status}</span>
              </li>
            </ul>
            <p
              :if={row.containers == [] and row.link != :remote}
              class="mt-2 pl-4 font-mono text-xs text-on-surface-variant"
            >
              no container on this host
            </p>
          </li>
        </ul>
      </.panel>

      <.panel title="Telemetry" meta="counted since boot">
        <p :if={@telemetry == []} class="font-mono text-xs text-on-surface-variant">
          No events recorded yet.
        </p>
        <ul :if={@telemetry != []} class="divide-y divide-outline-variant/40">
          <li
            :for={entry <- @telemetry}
            class="flex flex-wrap items-baseline justify-between gap-3 py-2 font-mono text-xs"
          >
            <span class="text-on-surface">{event_label(entry.event)}</span>
            <span class={Ops.status_class(entry.outcome)}>{entry.outcome}</span>
            <span class="text-on-surface-variant">{entry.count}×</span>
            <span class="text-on-surface-variant">{seen_ago(entry.last_seen_ms)}</span>
          </li>
        </ul>
      </.panel>

      <p class="font-mono text-xs text-on-surface-variant">
        Process state, message queues and stacktraces live on the <a
          href="/dashboard"
          class="text-primary-container hover:underline"
        >BEAM dashboard</a>.
      </p>
    </div>
    """
  end

  # -- labels ----------------------------------------------------------------

  defp link_label(:linked), do: "Linked"
  defp link_label(:orphan_container), do: "Orphan container"
  defp link_label(:process_without_container), do: "Process without container"
  defp link_label(:attempt_without_process), do: "Attempt without process"
  defp link_label(:remote), do: "Remote node"

  defp link_class(:linked), do: "text-status-succeeded"
  defp link_class(:orphan_container), do: "text-status-failed"
  defp link_class(:attempt_without_process), do: "text-status-failed"
  defp link_class(:process_without_container), do: "text-status-running"
  defp link_class(:remote), do: "text-on-surface-variant"

  defp node_label(%{node_id: nil}), do: "node —"
  defp node_label(%{node_id: node_id}), do: "node #{node_id}"

  defp process_label(nil), do: "none"
  defp process_label(pid) when is_pid(pid), do: inspect(pid)

  defp short_container(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_container(_id), do: "—"

  defp event_label(event) when is_list(event), do: Enum.map_join(event, ".", &Atom.to_string/1)
  defp event_label(event), do: to_string(event)

  defp runtime_ok?(%{runtime: :ok}), do: true
  defp runtime_ok?(_snapshot), do: false

  defp runtime_label(%{runtime: :ok}), do: "reachable"
  defp runtime_label(%{runtime: :never_polled}), do: "not polled yet"
  defp runtime_label(%{runtime: {:error, _reason}}), do: "unreachable"
  defp runtime_label(_snapshot), do: "unknown"

  defp empty_reason(%{runtime: {:error, reason}}),
    do: "The container runtime is unreachable (#{inspect(reason)}); containers cannot be listed."

  defp empty_reason(%{runtime: :never_polled}), do: "Waiting for the first census."

  defp empty_reason(_snapshot),
    do: "Nothing is running: no attempt process, no container, no claimed attempt."

  defp census_age(%{taken_at: nil}), do: "never polled"
  defp census_age(%{taken_at: taken_at}), do: "polled #{Ops.age(taken_at)} ago"

  defp seen_ago(last_seen_ms) when is_integer(last_seen_ms) do
    seconds = max(div(System.system_time(:millisecond) - last_seen_ms, 1_000), 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3_600)}h ago"
    end
  end

  defp seen_ago(_last_seen_ms), do: "—"

  # -- components ------------------------------------------------------------

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
