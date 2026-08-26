defmodule OmashikiWeb.JobLive do
  @moduledoc "Operator inspection and control for one admitted job."

  use OmashikiWeb, :live_view

  alias Omashiki.Jobs
  alias Omashiki.Jobs.Api
  alias OmashikiWeb.OperationHelpers, as: Ops

  @refresh_ms 2_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Omashiki.PubSub, "jobs")
      Phoenix.PubSub.subscribe(Omashiki.PubSub, "job:#{id}")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Job · #{String.slice(id, 0, 8)}")
     |> assign(:active_tab, :queue)
     |> assign(:job_id, id)
     |> assign_detail()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_detail(socket)}
  end

  def handle_info({:job_updated, job_id}, socket) when job_id == socket.assigns.job_id,
    do: {:noreply, assign_detail(socket)}

  def handle_info({:job_event, _event}, socket), do: {:noreply, assign_detail(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel", _params, %{assigns: %{detail: %{job: job}}} = socket)
      when job.status in ~w(blocked queued provisioning running) do
    case Jobs.cancel(job) do
      {:ok, _cancelled} ->
        notify(job.id)
        {:noreply, socket |> put_flash(:info, "Job cancelled.") |> assign_detail()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cancellation rejected: #{format_reason(reason)}")}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Only active jobs can be cancelled.")}

  @impl true
  def handle_event("retry", _params, %{assigns: %{detail: %{job: job}}} = socket)
      when job.status in ~w(failed cancelled) do
    case Jobs.retry(job) do
      {:ok, _retried} ->
        notify(job.id)

        {:noreply,
         socket |> put_flash(:info, "Job requeued for another attempt.") |> assign_detail()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Retry rejected: #{format_reason(reason)}")}
    end
  end

  def handle_event("retry", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Only failed or cancelled jobs can be retried.")}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp notify(job_id) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "jobs", {:job_updated, job_id})
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "job:#{job_id}", {:job_updated, job_id})
  end

  defp assign_detail(socket) do
    case Api.detail(socket.assigns.job_id, socket.assigns.current_user) do
      {:ok, detail} ->
        attempt = List.last(detail.attempts)
        steps_by_attempt = Enum.group_by(detail.steps, & &1.attempt_id)
        usage_total = Enum.sum(Enum.map(detail.usage, &(&1.input_tokens + &1.output_tokens)))

        socket
        |> assign(:detail, detail)
        |> assign(:attempt, attempt)
        |> assign(:steps_by_attempt, steps_by_attempt)
        |> assign(:usage_total, usage_total)

      {:error, _reason} ->
        socket
        |> assign(:detail, nil)
        |> assign(:attempt, nil)
        |> assign(:steps_by_attempt, %{})
        |> assign(:usage_total, 0)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@detail == nil} class="py-12">
      <p class="font-label text-label-md tracking-[0.25em] uppercase text-status-failed">
        Job not found
      </p>
      <p class="mt-2 font-mono text-sm text-on-surface-variant">
        The job is missing or not visible to this operator.
      </p>
    </div>

    <div :if={@detail != nil} class="flex flex-col gap-6 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4 border-b border-outline-variant pb-5">
        <div>
          <p class="font-mono text-xs text-on-surface-variant">job {@detail.job.id}</p>
          <div class="mt-2 flex flex-wrap items-center gap-3">
            <h1 class="font-headline italic text-3xl text-on-surface">Job details</h1>
            <span class={[
              "font-label text-label-md uppercase tracking-[0.2em]",
              Ops.status_class(@detail.job.status)
            ]}>{Ops.status_label(@detail.job.status)}</span>
          </div>
        </div>
        <div class="flex flex-wrap gap-3">
          <button
            :if={@detail.job.status in ~w(blocked queued provisioning running)}
            type="button"
            phx-click="cancel"
            class="border border-status-failed/50 px-4 py-2 font-label text-label-sm uppercase tracking-[0.2em] text-status-failed hover:border-status-failed"
          >Cancel</button>
          <button
            :if={@detail.job.status in ~w(failed cancelled)}
            type="button"
            phx-click="retry"
            class="border border-primary-container/50 px-4 py-2 font-label text-label-sm uppercase tracking-[0.2em] text-primary-container hover:border-primary-container"
          >Retry</button>
        </div>
      </header>

      <div class="grid gap-6 lg:grid-cols-2">
        <.panel title="Execution identity">
          <dl class="grid grid-cols-[minmax(8rem,1fr)_minmax(0,2fr)] gap-y-3 font-mono text-xs">
            <dt class="text-on-surface-variant">client</dt><dd class="truncate text-right text-on-surface">
              {@current_user.username}
            </dd>
            <dt class="text-on-surface-variant">repository</dt><dd class="truncate text-right text-on-surface">
              {@detail.job.repository}
            </dd>
            <dt class="text-on-surface-variant">environment</dt><dd class="truncate text-right text-on-surface">
              {@detail.job.environment}
            </dd>
            <dt class="text-on-surface-variant">parent</dt><dd class="truncate text-right text-on-surface">
              {if @detail.parent, do: @detail.parent.id, else: "none"}
            </dd>
            <dt class="text-on-surface-variant">attempt</dt><dd class="text-right text-on-surface">
              {@detail.job.current_attempt}
            </dd>
            <dt class="text-on-surface-variant">correlation</dt><dd class="truncate text-right text-on-surface">
              {@detail.job.correlation_id}
            </dd>
          </dl>
        </.panel>

        <.panel title="Payload summary">
          <% summary = Ops.payload_summary(@detail.job.payload) %>
          <p class="font-mono text-sm text-on-surface">
            {length(summary.keys)} top-level keys · {summary.bytes} bytes
          </p>
          <p class="mt-3 font-mono text-xs text-on-surface-variant">
            {Enum.join(summary.keys, " · ")}
          </p>
          <p class="mt-4 font-mono text-xs text-on-surface-variant">
            payload hash <span class="text-on-surface">{@detail.job.payload_hash}</span>
          </p>
        </.panel>

        <.panel title="Attempts">
          <ul class="divide-y divide-outline-variant/40">
            <li
              :for={attempt <- @detail.attempts}
              class="flex flex-wrap items-baseline justify-between gap-3 py-3 first:pt-0 last:pb-0"
            >
              <span class="font-mono text-xs text-on-surface">attempt {attempt.number}</span>
              <span class={["font-mono text-xs uppercase", Ops.status_class(attempt.status)]}>{attempt.status}</span>
              <%!-- Which machine ran it. Per attempt, not per job: a retry can
                    land on a different node than the attempt it replaces. --%>
              <span class="font-mono text-xs text-on-surface-variant">node {attempt.node_id || "—"}</span>
              <span class="font-mono text-xs text-on-surface-variant">{Ops.timestamp(
                attempt.finished_at || attempt.started_at
              )}</span>
            </li>
          </ul>
        </.panel>

        <.panel title="Usage">
          <p class="font-headline italic text-3xl text-on-surface">
            {Ops.format_tokens(@usage_total)}
          </p>
          <p class="mt-1 font-mono text-xs text-on-surface-variant">
            input + output tokens across {@detail.job.current_attempt} attempt(s)
          </p>
          <p :if={@detail.usage == []} class="mt-4 font-mono text-xs text-on-surface-variant">
            No usage recorded.
          </p>
        </.panel>
      </div>

      <.panel title="Steps">
        <div
          :if={@attempt == nil or Map.get(@steps_by_attempt, @attempt.id, []) == []}
          class="font-mono text-xs text-on-surface-variant"
        >
          No steps recorded.
        </div>
        <ul
          :if={@attempt != nil and Map.get(@steps_by_attempt, @attempt.id, []) != []}
          class="divide-y divide-outline-variant/40"
        >
          <li
            :for={step <- Map.get(@steps_by_attempt, @attempt.id, [])}
            class="grid gap-2 py-3 sm:grid-cols-[3rem_1fr_auto] sm:items-baseline"
          >
            <span class="font-mono text-xs text-on-surface-variant">{step.sequence}</span>
            <div>
              <p class="font-mono text-sm text-on-surface">{step.key}</p><p class="font-mono text-xs text-on-surface-variant">
                {step.kind}
              </p>
            </div>
            <span class={["font-mono text-xs uppercase", Ops.status_class(step.status)]}>{step.status}</span>
          </li>
        </ul>
      </.panel>

      <div class="grid gap-6 lg:grid-cols-2">
        <.panel title="Branch and SHAs">
          <dl class="grid gap-y-3 font-mono text-xs">
            <dt class="text-on-surface-variant">branch</dt><dd class="break-all text-on-surface">
              {if @attempt, do: @attempt.branch || "—", else: "—"}
            </dd>
            <dt class="text-on-surface-variant">base SHA</dt><dd class="break-all text-on-surface">
              {if @attempt, do: @attempt.base_sha || "—", else: "—"}
            </dd>
            <dt class="text-on-surface-variant">head SHA</dt><dd class="break-all text-on-surface">
              {if @attempt, do: @attempt.head_sha || "—", else: "—"}
            </dd>
          </dl>
        </.panel>

        <.panel title="Result or error">
          <pre
            :if={@detail.job.terminal_result}
            class="term-scroll max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-status-succeeded"
          >{Ops.json(@detail.job.terminal_result)}</pre>
          <pre
            :if={@detail.job.terminal_error}
            class="term-scroll max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-status-failed"
          >{Ops.json(@detail.job.terminal_error)}</pre>
          <p
            :if={is_nil(@detail.job.terminal_result) and is_nil(@detail.job.terminal_error)}
            class="font-mono text-xs text-on-surface-variant"
          >
            No terminal result yet.
          </p>
        </.panel>
      </div>

      <.panel title="Logs and events">
        <ul :if={@detail.events != []} class="divide-y divide-outline-variant/40">
          <li
            :for={event <- Enum.reverse(@detail.events)}
            class="grid gap-2 py-3 sm:grid-cols-[4rem_1fr_auto] sm:items-baseline"
          >
            <span class="font-mono text-xs text-on-surface-variant">#{event.sequence}</span>
            <div>
              <p class="font-mono text-sm text-on-surface">{event.type}</p><p class="font-mono text-xs text-on-surface-variant">
                attempt {event.attempt} · {Ops.timestamp(event.occurred_at)}
              </p>
            </div>
            <span class={["font-mono text-xs uppercase", Ops.status_class(event.status)]}>{event.status}</span>
          </li>
        </ul>
        <p :if={@detail.events == []} class="font-mono text-xs text-on-surface-variant">
          No events recorded.
        </p>
      </.panel>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section class="border border-outline-variant bg-surface-container p-5">
      <h2 class="mb-4 font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
