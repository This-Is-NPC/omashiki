defmodule OmashikiWeb.TaskViewsLive do
  @moduledoc """
  Display-only task views declared in the operator's `ui.toml`.

  The screen reads jobs and the views file. It has no event that changes a
  job, and the views file never reaches admission, dispatch, or the registry.
  Selecting a view or a task only patches the URL.
  """

  use OmashikiWeb, :live_view

  alias Omashiki.Jobs
  alias Omashiki.Jobs.Api
  alias Omashiki.Worker.Presence
  alias OmashikiWeb.Layouts
  alias OmashikiWeb.OperationHelpers, as: Ops
  alias OmashikiWeb.TaskViews
  alias OmashikiWeb.TaskViews.{Graph, Rows}
  alias Omashiki.Fleet

  # Job changes arrive as PubSub events. The clock only advances relative times
  # and re-reads the views file and in-memory worker presence; it never reads
  # jobs. The resync covers changes that publish nothing on this node: recovery
  # sweeps and other nodes, whose PubSub is not clustered with this one.
  @clock_ms 1_000
  @resync_ms 15_000
  @event_debounce_ms 250
  @detail_event_limit 40
  @detail_fields ~w(repository environment plugin sink priority attempt worker branch
                    correlation_id submitted started finished wait duration result)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Omashiki.PubSub, "jobs")
      Fleet.subscribe()
      schedule_clock()
      schedule_resync()
    end

    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Home")
     |> assign(:active_tab, :home)
     |> assign(:wide_layout, true)
     |> assign(:views_file, TaskViews.load())
     |> assign(:requested_view, nil)
     |> assign(:job_id, nil)
     |> assign(:reload_pending, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:requested_view, present(params["view"]))
     |> assign(:job_id, present(params["job"]))
     |> refresh_screen()}
  end

  @impl true
  def handle_info(:clock, socket) do
    schedule_clock()
    previous = socket.assigns.views_file
    file = TaskViews.refresh(previous)
    socket = assign(socket, :views_file, file)

    if file == previous,
      do: {:noreply, advance_clock(socket)},
      else: {:noreply, refresh_screen(socket)}
  end

  def handle_info(:resync, socket) do
    schedule_resync()
    {:noreply, refresh_screen(socket)}
  end

  def handle_info(:reload_rows, socket),
    do: {:noreply, socket |> assign(:reload_pending, false) |> refresh_screen()}

  # Job transitions and fleet changes arrive in bursts; one read covers the
  # whole burst.
  def handle_info({event, _id}, %{assigns: %{reload_pending: false}} = socket)
      when event in [:job_updated, :fleet_updated] do
    Process.send_after(self(), :reload_rows, @event_debounce_ms)
    {:noreply, assign(socket, :reload_pending, true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_clock, do: Process.send_after(self(), :clock, @clock_ms)
  defp schedule_resync, do: Process.send_after(self(), :resync, @resync_ms)

  defp advance_clock(socket) do
    now = DateTime.utc_now()
    presence = Presence.list(now)

    if socket.assigns.graph && Graph.stale_changed?(socket.assigns.graph, presence) do
      refresh_screen(socket)
    else
      blocks =
        Enum.map(socket.assigns.blocks, fn
          {:workers, _workers} -> {:workers, presence}
          block -> block
        end)

      socket
      |> assign(:now, now)
      |> assign(:blocks, blocks)
    end
  end

  defp refresh_screen(socket) do
    %{views_file: file, requested_view: requested, current_user: user} = socket.assigns
    now = DateTime.utc_now()

    {view, missing_view} =
      case TaskViews.find(file, requested) do
        {:ok, view} -> {view, nil}
        {:fallback, view} -> {view, requested}
      end

    rows = Rows.load(user, view, now)

    socket
    |> assign(:now, now)
    |> assign(:view, view)
    |> assign(:missing_view, missing_view)
    |> assign(:rows, rows)
    |> assign(:groups, Rows.groups(rows, view))
    |> assign(:blocks, Enum.map(view.blocks, &{&1, block_data(&1, rows, view)}))
    |> assign(:graph, if(view.layout == :graph, do: Graph.build(user, view, now)))
    |> assign(:detail, detail(socket.assigns.job_id, user))
  end

  defp block_data(:status_counts, rows, view), do: Rows.status_counts(rows, view)
  defp block_data(:workers, _rows, _view), do: Presence.list()

  defp block_data(:slots, _rows, _view) do
    Jobs.cluster_capacity()
  rescue
    _ -> %{capacity: 0, active: 0}
  end

  defp detail(nil, _user), do: nil

  defp detail(job_id, user) do
    case Api.detail(job_id, user) do
      {:ok, detail} ->
        attempt = List.last(detail.attempts)

        steps =
          if attempt, do: Enum.filter(detail.steps, &(&1.attempt_id == attempt.id)), else: []

        Map.put(detail, :row, %{job: detail.job, attempt: attempt, steps: steps})

      {:error, _reason} ->
        :not_found
    end
  end

  defp view_path(view_name, job_id \\ nil) do
    params = Enum.reject([view: view_name, job: job_id], fn {_key, value} -> is_nil(value) end)
    ~p"/?#{params}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div class="min-w-0">
          <h1 class="font-headline italic text-3xl text-on-surface">{@view.title}</h1>
          <p class="mt-1 break-all font-mono text-sm text-on-surface-variant">
            {source_note(@views_file)}
          </p>
        </div>
        <span class="flex items-center gap-2 font-mono text-xs text-on-surface-variant">
          {if @view.layout == :graph, do: fleet_count(@graph), else: task_count(@rows, @view)}
          <span aria-hidden="true">·</span>
          <span class="hidden items-center gap-1.5 text-status-success phx-connected:inline-flex">
            <span class="h-1.5 w-1.5 animate-status-pulse bg-current" aria-hidden="true"></span> live
          </span>
          <span class="text-status-awaiting phx-connected:hidden">connecting…</span>
        </span>
      </header>

      <nav
        :if={length(@views_file.views) > 1}
        aria-label="Views"
        class="flex flex-wrap gap-x-6 gap-y-3 border-b border-outline-variant pb-3"
      >
        <.link
          :for={view <- @views_file.views}
          patch={view_path(view.name)}
          class={Layouts.nav_link_class(view.name, %{active_tab: @view.name})}
          aria-current={if view.name == @view.name, do: "page", else: nil}
        >
          {view.title}
        </.link>
      </nav>

      <.alert_banner :if={@views_file.errors != []} kind={:error}>
        <:title>Views file rejected</:title>
        <p>The screen keeps the last valid views until the file is corrected.</p>
        <ul class="mt-2 list-disc pl-5">
          <li :for={error <- @views_file.errors} class="break-words">{error}</li>
        </ul>
      </.alert_banner>

      <.alert_banner :if={@missing_view} kind={:warning}>
        View "{@missing_view}" is not declared. Showing "{@view.name}".
      </.alert_banner>

      <div :if={@blocks != []} class="flex flex-wrap gap-4">
        <.block :for={{kind, data} <- @blocks} kind={kind} data={data} />
      </div>

      <p
        :if={@rows == [] and @view.layout == :list}
        class="border border-outline-variant bg-surface-container p-5 font-mono text-xs text-on-surface-variant"
      >
        No tasks match this view.
      </p>

      <.task_list
        :if={@view.layout == :list and @rows != []}
        groups={@groups}
        view={@view}
        now={@now}
      />
      <.task_board :if={@view.layout == :board} groups={@groups} view={@view} now={@now} />
      <.task_graph :if={@view.layout == :graph} graph={@graph} view={@view} now={@now} />

      <div
        :if={@detail}
        id="task-detail"
        class="fixed inset-0 z-40 flex justify-end"
        phx-window-keydown={JS.patch(view_path(@view.name))}
        phx-key="escape"
      >
        <.link patch={view_path(@view.name)} class="absolute inset-0 bg-scrim/60">
          <span class="sr-only">Close task details</span>
        </.link>
        <aside
          class="relative flex h-full w-full max-w-xl flex-col gap-6 overflow-y-auto border-l border-outline-variant bg-surface-container-low p-6"
          aria-label="Task details"
        >
          <.task_detail detail={@detail} view={@view} now={@now} />
        </aside>
      </div>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :data, :any, required: true

  defp block(%{kind: :status_counts} = assigns) do
    ~H"""
    <section class="w-full border border-outline-variant bg-surface-container p-5">
      <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
        Status
      </h2>
      <dl class="mt-3 flex flex-wrap gap-x-8 gap-y-3">
        <div :for={{status, count} <- @data}>
          <dt class="font-label text-label-sm uppercase tracking-[0.18em] text-on-surface-variant">
            {Ops.status_label(status)}
          </dt>
          <dd class={[
            "mt-1 font-headline italic text-2xl tabular-nums",
            if(count > 0, do: Ops.status_class(status), else: "text-on-surface-variant")
          ]}>
            {count}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  defp block(%{kind: :slots} = assigns) do
    ~H"""
    <section class="min-w-[14rem] flex-1 border border-outline-variant bg-surface-container p-5">
      <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
        Slots
      </h2>
      <p class="mt-3 font-headline italic text-3xl tabular-nums text-on-surface">
        {@data.active} / {@data.capacity}
      </p>
      <p class="mt-1 font-mono text-xs text-on-surface-variant">
        {max(@data.capacity - @data.active, 0)} free across nodes
      </p>
    </section>
    """
  end

  defp block(%{kind: :workers} = assigns) do
    assigns =
      assign(assigns,
        live: Enum.count(assigns.data, &(not &1.stale?)),
        stale: Enum.count(assigns.data, & &1.stale?)
      )

    ~H"""
    <section class="min-w-[14rem] flex-1 border border-outline-variant bg-surface-container p-5">
      <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
        Workers
      </h2>
      <p class="mt-3 font-headline italic text-3xl tabular-nums text-on-surface">{@live} live</p>
      <p class="mt-1 font-mono text-xs text-on-surface-variant">{@stale} stale</p>
    </section>
    """
  end

  attr :groups, :list, required: true
  attr :view, :map, required: true
  attr :now, :any, required: true

  defp task_list(assigns) do
    ~H"""
    <section
      :for={{group, rows} <- @groups}
      :if={rows != []}
      class="border border-outline-variant bg-surface-container"
    >
      <header :if={group} class="flex items-baseline justify-between gap-3 px-5 pt-4">
        <h2 class={[
          "font-label text-label-md tracking-[0.25em] uppercase",
          group_class(@view.group_by, group)
        ]}>
          {group_label(@view.group_by, group)}
        </h2>
        <span class="font-mono text-xs text-on-surface-variant">{length(rows)}</span>
      </header>
      <div class="overflow-x-auto">
        <%!-- Grouped tables share column widths so the groups line up. --%>
        <table class={["w-full font-mono text-xs", group && "table-fixed"]}>
          <thead>
            <tr class="text-left">
              <th
                :for={field <- @view.fields}
                scope="col"
                class="whitespace-nowrap px-5 py-3 font-label text-label-sm font-normal uppercase tracking-[0.18em] text-on-surface-variant"
              >
                {Rows.label(field)}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant/40">
            <tr
              :for={row <- rows}
              id={"task-#{row.job.id}"}
              phx-click={JS.patch(view_path(@view.name, row.job.id))}
              class="cursor-pointer transition-colors hover:bg-surface-container-high"
            >
              <td
                :for={{field, index} <- Enum.with_index(@view.fields)}
                class="max-w-[28rem] px-5 py-3 align-baseline"
              >
                <.cell
                  row={row}
                  field={field}
                  now={@now}
                  patch={if index == 0, do: view_path(@view.name, row.job.id)}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :groups, :list, required: true
  attr :view, :map, required: true
  attr :now, :any, required: true

  defp task_board(assigns) do
    ~H"""
    <%!-- The board fills the viewport below its top edge (BoardHeight hook
          measures that edge; 2.5rem is the bottom padding of main and of this
          screen). Columns stretch to that height and each list scrolls inside
          its own column. --%>
    <div
      id="task-board"
      phx-hook="BoardHeight"
      class="flex h-[calc(100dvh_-_var(--board-top,16rem)_-_2.5rem)] min-h-[20rem] gap-4 overflow-x-auto pb-2"
    >
      <section
        :for={{group, rows} <- @groups}
        class="flex min-h-0 min-w-[14rem] flex-1 basis-0 flex-col border border-outline-variant bg-surface-container"
        aria-label={group_label(@view.group_by, group)}
      >
        <header class="flex items-center justify-between gap-3 border-b border-outline-variant px-4 py-3">
          <h2 class={[
            "flex min-w-0 items-center gap-2 font-label text-label-md tracking-[0.25em] uppercase",
            group_class(@view.group_by, group)
          ]}>
            <span class="h-1.5 w-1.5 shrink-0 bg-current" aria-hidden="true"></span>
            <span class="truncate">{group_label(@view.group_by, group)}</span>
          </h2>
          <span class="font-mono text-xs tabular-nums text-on-surface-variant">{length(rows)}</span>
        </header>
        <ul class="term-scroll flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-2">
          <li :for={row <- rows} id={"task-#{row.job.id}"}>
            <.link
              patch={view_path(@view.name, row.job.id)}
              class="block border border-outline-variant/60 bg-surface p-3 transition-colors hover:border-on-surface-variant"
            >
              <p class="font-mono text-sm leading-snug">
                <.cell row={row} field={hd(@view.fields)} now={@now} />
              </p>
              <dl :if={tl(@view.fields) != []} class="mt-2 grid gap-1 font-mono text-xs">
                <div
                  :for={field <- tl(@view.fields)}
                  class="flex items-baseline justify-between gap-3"
                >
                  <dt class="shrink-0 text-on-surface-variant">{Rows.label(field)}</dt>
                  <dd class="min-w-0 truncate text-right">
                    <.cell row={row} field={field} now={@now} />
                  </dd>
                </div>
              </dl>
            </.link>
          </li>
          <li :if={rows == []} class="px-2 py-3 font-mono text-xs text-on-surface-variant">
            No tasks
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :graph, :map, required: true
  attr :view, :map, required: true
  attr :now, :any, required: true

  defp task_graph(assigns) do
    ~H"""
    <section id="task-graph" aria-label="Fleet graph" class="flex flex-col">
      <div class="flex flex-wrap items-center gap-3 self-start border border-outline-variant bg-surface-container px-4 py-3">
        <span class="h-2 w-2 bg-primary-container" aria-hidden="true"></span>
        <span class="font-label text-label-md uppercase tracking-[0.25em] text-on-surface">
          House
        </span>
        <span class="font-mono text-xs text-on-surface-variant">
          {@graph.counts.live} live · {@graph.counts.stale} stale · {@graph.counts.running}/{@graph.counts.containers} containers running
        </span>
      </div>

      <p
        :if={@graph.nodes == []}
        class="ml-6 border-l border-outline-variant py-4 pl-8 font-mono text-xs text-on-surface-variant"
      >
        No node runs jobs for this house.
      </p>

      <ul :if={@graph.nodes != []} class="ml-6 border-l border-outline-variant">
        <li
          :for={node <- @graph.nodes}
          id={dom_id("node", node.machine_id)}
          class="relative py-3 pl-8 before:absolute before:left-0 before:top-10 before:w-8 before:border-t before:border-outline-variant before:content-['']"
        >
          <div class="flex flex-wrap items-start gap-x-6 gap-y-3">
            <.fleet_node node={node} now={@now} />
            <ul
              class="flex min-w-0 flex-1 flex-wrap gap-3"
              aria-label={"Containers on #{node.machine_id}"}
            >
              <%!-- Containers fade in when created and fade out when removed. --%>
              <li
                :for={container <- node.containers}
                id={dom_id("container", container.id)}
                class="w-64"
                phx-mounted={
                  JS.transition(
                    {"transition-all duration-500 ease-out", "opacity-0 -translate-y-1",
                     "opacity-100 translate-y-0"}
                  )
                }
                phx-remove={
                  JS.transition({"transition-all duration-500 ease-in", "opacity-100", "opacity-0"},
                    time: 500
                  )
                }
              >
                <.fleet_container container={container} view={@view} now={@now} />
              </li>
              <li
                :if={node.containers == []}
                class="self-center font-mono text-xs text-on-surface-variant"
              >
                idle
              </li>
            </ul>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :node, :map, required: true
  attr :now, :any, required: true

  defp fleet_node(assigns) do
    assigns = assign(assigns, :used, used_slots(assigns.node))

    ~H"""
    <div class={[
      "w-60 shrink-0 border bg-surface-container p-4",
      if(@node.stale?, do: "border-outline-variant/60 opacity-60", else: "border-outline-variant")
    ]}>
      <div class="flex items-center justify-between gap-3">
        <span class="min-w-0 truncate font-mono text-sm text-on-surface" title={@node.machine_id}>
          {@node.machine_id}
        </span>
        <span class={[
          "flex shrink-0 items-center gap-1.5 font-label text-label-sm uppercase tracking-[0.18em]",
          if(@node.stale?, do: "text-status-failed", else: "text-status-success")
        ]}>
          <span
            class={["h-1.5 w-1.5 bg-current", !@node.stale? && "animate-status-pulse"]}
            aria-hidden="true"
          ></span>
          {if @node.stale?, do: "stale", else: "live"}
        </span>
      </div>
      <p class="mt-1 font-mono text-xs text-on-surface-variant">
        {if @node.kind == :local, do: "this node", else: "worker"} · seen {last_seen(@node, @now)}
      </p>
      <div :if={@node.capacity} class="mt-3">
        <div class="flex justify-between font-mono text-xs text-on-surface-variant">
          <span>slots</span>
          <span class="tabular-nums text-on-surface">{@used} / {@node.capacity}</span>
        </div>
        <div class="mt-1 h-1 bg-surface-container-highest">
          <div
            class="h-1 bg-primary-container transition-all"
            style={"width: #{slot_percent(@used, @node.capacity)}%"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :container, :map, required: true
  attr :view, :map, required: true
  attr :now, :any, required: true

  defp fleet_container(%{container: %{row: nil}} = assigns) do
    ~H"""
    <div class="border border-dashed border-outline-variant/60 bg-surface p-3">
      <.container_state container={@container} now={@now} />
      <p class="mt-2 font-mono text-sm text-on-surface">{String.slice(@container.id, 0, 12)}</p>
      <p class="mt-1 font-mono text-xs text-on-surface-variant">no visible job</p>
    </div>
    """
  end

  defp fleet_container(assigns) do
    ~H"""
    <.link
      patch={view_path(@view.name, @container.row.job.id)}
      class="block border border-outline-variant/60 bg-surface p-3 transition-colors hover:border-on-surface-variant"
    >
      <.container_state container={@container} now={@now} />
      <p class="mt-2 font-mono text-sm leading-snug">
        <.cell row={@container.row} field={hd(@view.fields)} now={@now} />
      </p>
      <dl :if={tl(@view.fields) != []} class="mt-2 grid gap-1 font-mono text-xs">
        <div :for={field <- tl(@view.fields)} class="flex items-baseline justify-between gap-3">
          <dt class="shrink-0 text-on-surface-variant">{Rows.label(field)}</dt>
          <dd class="min-w-0 truncate text-right">
            <.cell row={@container.row} field={field} now={@now} />
          </dd>
        </div>
      </dl>
    </.link>
    """
  end

  attr :container, :map, required: true
  attr :now, :any, required: true

  defp container_state(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <span class={[
        "flex items-center gap-1.5 font-label text-label-sm uppercase tracking-[0.18em]",
        container_state_class(@container.state)
      ]}>
        <span
          class={["h-1.5 w-1.5 bg-current", @container.state == "running" && "animate-status-pulse"]}
          aria-hidden="true"
        ></span>
        {@container.state}
      </span>
      <span class="font-mono text-xs text-on-surface-variant">
        {container_age(@container, @now)}
      </span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :field, :string, required: true
  attr :now, :any, required: true
  attr :patch, :string, default: nil

  defp cell(assigns) do
    {text, class} = Rows.cell(assigns.row, assigns.field, assigns.now)
    assigns = assign(assigns, text: text, class: class || "text-on-surface")

    ~H"""
    <.link :if={@patch} patch={@patch} class={["break-words hover:underline", @class]}>{@text}</.link>
    <span :if={!@patch} class={["break-words", @class]}>{@text}</span>
    """
  end

  attr :detail, :any, required: true
  attr :view, :map, required: true
  attr :now, :any, required: true

  defp task_detail(%{detail: :not_found} = assigns) do
    ~H"""
    <header class="flex items-start justify-between gap-4">
      <div>
        <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-status-failed">
          Task not found
        </h2>
        <p class="mt-2 font-mono text-sm text-on-surface-variant">
          The task is missing or not visible to this operator.
        </p>
      </div>
      <.close_link view={@view} />
    </header>
    """
  end

  defp task_detail(assigns) do
    assigns = assign(assigns, :context, Rows.payload_context(assigns.detail.job))

    ~H"""
    <header class="flex items-start justify-between gap-4">
      <div class="min-w-0">
        <p class="break-all font-mono text-xs text-on-surface-variant">task {@detail.job.id}</p>
        <h2 class="mt-2 break-words font-headline italic text-2xl text-on-surface">
          {Rows.title(@detail.row)}
        </h2>
        <p class={[
          "mt-2 font-label text-label-md uppercase tracking-[0.2em]",
          Ops.status_class(@detail.job.status)
        ]}>
          {Ops.status_label(@detail.job.status)}
        </p>
      </div>
      <.close_link view={@view} />
    </header>

    <.detail_section title="Identity">
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-y-2 font-mono text-xs">
        <div :for={field <- detail_fields()} class="contents">
          <dt class="text-on-surface-variant">{Rows.label(field)}</dt>
          <dd class="min-w-0"><.cell row={@detail.row} field={field} now={@now} /></dd>
        </div>
      </dl>
    </.detail_section>

    <.detail_section title="Instruction">
      <pre class="term-scroll max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-on-surface">{Rows.payload(@detail.job, "instruction") || "—"}</pre>
    </.detail_section>

    <.detail_section :if={@context} title="Context">
      <pre class="term-scroll max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-on-surface">{Ops.json(@context)}</pre>
    </.detail_section>

    <.detail_section title="Steps">
      <p :if={@detail.row.steps == []} class="font-mono text-xs text-on-surface-variant">
        No steps recorded.
      </p>
      <ol :if={@detail.row.steps != []} class="divide-y divide-outline-variant/40">
        <li
          :for={step <- @detail.row.steps}
          class="grid grid-cols-[minmax(0,1fr)_auto_auto] items-baseline gap-3 py-2 font-mono text-xs"
        >
          <span class="min-w-0 break-words text-on-surface">
            {step.key}
            <span :if={step.kind != step.key} class="text-on-surface-variant">{step.kind}</span>
          </span>
          <span class="text-on-surface-variant">
            {Rows.span(step.started_at, step.finished_at || @now) || "—"}
          </span>
          <span class={["uppercase", Ops.status_class(step.status)]}>{step.status}</span>
        </li>
      </ol>
    </.detail_section>

    <.detail_section
      :if={@detail.job.terminal_result || @detail.job.terminal_error}
      title="Result"
    >
      <pre
        :if={@detail.job.terminal_result}
        class="term-scroll max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-status-succeeded"
      >{Ops.json(@detail.job.terminal_result)}</pre>
      <pre
        :if={@detail.job.terminal_error}
        class="term-scroll max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-status-failed"
      >{Ops.json(@detail.job.terminal_error)}</pre>
    </.detail_section>

    <.detail_section title="Events">
      <p :if={@detail.events == []} class="font-mono text-xs text-on-surface-variant">
        No events recorded.
      </p>
      <ol :if={@detail.events != []} class="divide-y divide-outline-variant/40">
        <li
          :for={event <- recent_events(@detail.events)}
          class="grid grid-cols-[minmax(0,1fr)_auto] gap-x-3 gap-y-1 py-2 font-mono text-xs"
        >
          <span class="min-w-0 break-words text-on-surface">
            {event.type}<span :if={event.step} class="text-on-surface-variant"> · {event.step}</span>
          </span>
          <span class={["uppercase", Ops.status_class(event.status)]}>{event.status}</span>
          <time class="col-span-2 text-on-surface-variant" datetime={event.occurred_at}>
            {Ops.timestamp(event.occurred_at)} · attempt {event.attempt}
          </time>
        </li>
      </ol>
    </.detail_section>

    <.detail_section :if={@detail.webhooks != []} title="Webhooks">
      <ul class="divide-y divide-outline-variant/40">
        <li
          :for={delivery <- @detail.webhooks}
          class="flex flex-wrap items-baseline justify-between gap-3 py-2 font-mono text-xs"
        >
          <span class={["uppercase", Ops.status_class(delivery.status)]}>{delivery.status}</span>
          <span class="text-on-surface-variant">attempt {delivery.attempts}</span>
          <span class="text-on-surface-variant">HTTP {delivery.last_response_status || "—"}</span>
        </li>
      </ul>
    </.detail_section>
    """
  end

  attr :view, :map, required: true

  defp close_link(assigns) do
    ~H"""
    <.link
      patch={view_path(@view.name)}
      class="shrink-0 font-label text-label-md uppercase tracking-[0.2em] text-on-surface-variant hover:text-on-surface"
    >
      Close
    </.link>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp detail_section(assigns) do
    ~H"""
    <section>
      <h3 class="mb-3 font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
        {@title}
      </h3>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp detail_fields, do: @detail_fields

  defp recent_events(events), do: events |> Enum.reverse() |> Enum.take(@detail_event_limit)

  defp group_label(nil, _group), do: "All tasks"
  defp group_label(:status, status), do: Ops.status_label(status)
  defp group_label(_key, group), do: group

  defp group_class(:status, status), do: Ops.status_class(status)
  defp group_class(_key, _group), do: "text-on-surface-variant"

  defp source_note(%TaskViews{source: :file, path: path}), do: "Views from #{path}"

  defp source_note(%TaskViews{source: :builtin, path: path}),
    do: "Built-in views · create #{path} to change them"

  defp fleet_count(%{counts: counts}),
    do: "#{counts.nodes} nodes · #{counts.containers} containers"

  defp fleet_count(_graph), do: ""

  defp dom_id(prefix, value), do: prefix <> "-" <> String.replace(value, ~r/[^A-Za-z0-9_-]/, "-")

  defp used_slots(%{capacity: capacity, free_slots: free})
       when is_integer(capacity) and is_integer(free),
       do: max(capacity - free, 0)

  defp used_slots(_node), do: 0

  defp slot_percent(_used, 0), do: 0
  defp slot_percent(used, capacity), do: min(round(used * 100 / capacity), 100)

  defp last_seen(%{last_seen_at: %DateTime{} = at}, now), do: "#{Rows.span(at, now)} ago"
  defp last_seen(_node, _now), do: "never"

  defp container_state_class("running"), do: "text-status-running"

  defp container_state_class(state) when state in ["created", "restarting", "paused"],
    do: "text-status-awaiting"

  defp container_state_class("removing"), do: "text-status-cancelled"
  defp container_state_class(_state), do: "text-status-failed"

  defp container_age(%{started_at: %DateTime{} = at}, now), do: "up #{Rows.span(at, now)}"
  defp container_age(%{created_at: %DateTime{} = at}, now), do: "#{Rows.span(at, now)} ago"
  defp container_age(_container, _now), do: ""

  defp task_count(rows, view) do
    count = length(rows)

    cond do
      count >= view.limit -> "latest #{count} tasks"
      count == 1 -> "1 task"
      true -> "#{count} tasks"
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
