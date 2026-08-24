defmodule OmashikiWeb.QueueLive do
  @moduledoc "Operator queue inspection."

  use OmashikiWeb, :live_view

  alias Omashiki.Jobs.Api
  alias OmashikiWeb.OperationHelpers, as: Ops

  @refresh_ms 2_000
  @visible_statuses ~w(blocked queued provisioning running)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Omashiki.PubSub, "jobs")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Queue")
     |> assign(:active_tab, :queue)
     |> assign_queue()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_queue(socket)}
  end

  def handle_info({:job_updated, _job_id}, socket), do: {:noreply, assign_queue(socket)}
  def handle_info({:job_event, _event}, socket), do: {:noreply, assign_queue(socket)}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp assign_queue(socket) do
    jobs =
      socket.assigns.current_user
      |> Api.list_for_operator(limit: 100)
      |> Enum.filter(&(&1.status in @visible_statuses))
      |> Enum.group_by(&section/1)
      |> Map.new(fn {status, entries} ->
        {status, Enum.sort_by(entries, &{-&1.priority, &1.queued_at || &1.inserted_at})}
      end)

    socket
    |> assign(:blocked_jobs, Map.get(jobs, "blocked", []))
    |> assign(:queued_jobs, Map.get(jobs, "queued", []))
    |> assign(:running_jobs, Map.get(jobs, "running", []))
  end

  defp section(%{status: status}) when status in ["provisioning", "running"], do: "running"
  defp section(%{status: status}), do: status

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="font-headline italic text-3xl text-on-surface">Queue</h1>
          <p class="mt-1 font-mono text-sm text-on-surface-variant">
            Blocked, queued, and running jobs
          </p>
        </div>
        <span class="font-mono text-xs text-on-surface-variant">live state · no authoring</span>
      </header>

      <.job_section
        title="Blocked"
        status="blocked"
        jobs={@blocked_jobs}
        client={@current_user.username}
      />
      <.job_section
        title="Queued"
        status="queued"
        jobs={@queued_jobs}
        client={@current_user.username}
      />
      <.job_section
        title="Running"
        status="running"
        jobs={@running_jobs}
        client={@current_user.username}
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :status, :string, required: true
  attr :jobs, :list, required: true
  attr :client, :string, required: true

  defp job_section(assigns) do
    ~H"""
    <section class="border border-outline-variant bg-surface-container">
      <header class="flex flex-wrap items-baseline justify-between gap-3 border-b border-outline-variant px-5 py-4">
        <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
          {@title}
        </h2>
        <span class="font-mono text-xs text-on-surface-variant">{length(@jobs)} jobs</span>
      </header>
      <div :if={@jobs == []} class="px-5 py-8 font-mono text-xs text-on-surface-variant">
        No {@status} jobs.
      </div>
      <div :if={@jobs != []} class="overflow-x-auto">
        <table class="min-w-[48rem] w-full border-collapse text-left">
          <thead>
            <tr class="border-b border-outline-variant/60">
              <th
                :for={
                  label <- [
                    "job",
                    "client",
                    "age",
                    "priority",
                    "repository",
                    "environment",
                    "attempt"
                  ]
                }
                class="px-5 py-3 font-label text-label-sm font-normal uppercase tracking-[0.18em] text-on-surface-variant"
              >
                {label}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={job <- @jobs}
              class="border-b border-outline-variant/30 last:border-0 hover:bg-surface-container-high"
            >
              <td class="px-5 py-4">
                <.link
                  navigate={~p"/jobs/#{job.id}"}
                  class="font-mono text-xs text-primary-container hover:underline"
                >{Ops.short_id(job.id)}</.link>
                <span class={["ml-2 font-mono text-[10px] uppercase", Ops.status_class(job.status)]}>{Ops.status_label(
                  job.status
                )}</span>
              </td>
              <td class="px-5 py-4 font-mono text-xs text-on-surface">{@client}</td>
              <td class="px-5 py-4 font-mono text-xs text-on-surface-variant">
                {Ops.age(job.queued_at || job.inserted_at)}
              </td>
              <td class="px-5 py-4 font-mono text-xs text-on-surface">P{job.priority}</td>
              <td
                class="max-w-[12rem] truncate px-5 py-4 font-mono text-xs text-on-surface"
                title={job.repository}
              >
                {job.repository}
              </td>
              <td
                class="max-w-[12rem] truncate px-5 py-4 font-mono text-xs text-on-surface"
                title={job.environment}
              >
                {job.environment}
              </td>
              <td class="px-5 py-4 font-mono text-xs tabular-nums text-on-surface">
                {job.current_attempt}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end
end
