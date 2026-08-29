defmodule OmashikiWeb.ConfigLive do
  @moduledoc "Read-only repository, environment, runtime, and cache operations."

  use OmashikiWeb, :live_view

  alias Omashiki.Config
  alias Omashiki.Config.Rollout
  alias Omashiki.HostSettings
  alias Omashiki.Runtimes.CacheMaintenance
  alias OmashikiWeb.OperationHelpers, as: Ops

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Config")
     |> assign(:active_tab, :config)
     |> assign(:reload_result, nil)
     |> assign_config()}
  end

  @impl true
  def handle_event("reload_config", _params, socket) do
    result = Rollout.reload()

    socket =
      case result do
        {:ok, _info} -> assign_config(socket)
        _ -> socket
      end

    {:noreply, assign(socket, :reload_result, result)}
  end

  @impl true
  def handle_event("purge_cache", %{"group" => group}, socket) when is_binary(group) do
    result =
      if Config.get_cache(group) do
        safe_purge(group)
      else
        {:error, :unknown_group}
      end

    message =
      case result do
        {:ok, _} -> {:info, "Purged cache group #{group}."}
        {:error, :active} -> {:error, "Cache group #{group} is protected while leased."}
        {:error, :unknown_group} -> {:error, "Cache purge requires a configured group."}
        {:error, _} -> {:error, "Cache purge failed; no data was changed."}
      end

    {:noreply, socket |> put_flash(elem(message, 0), elem(message, 1)) |> assign_config()}
  end

  def handle_event("purge_cache", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Cache purge requires a configured group.")}

  defp assign_config(socket) do
    socket
    |> assign(:repositories, Config.repositories())
    |> assign(:environments, Config.environments())
    |> assign(:limits, HostSettings.get_limits())
    |> assign(:max_containers, HostSettings.get_max_concurrent_containers())
    |> assign(:cache_rows, cache_rows())
  end

  defp cache_rows do
    snapshots =
      try do
        CacheMaintenance.snapshots()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    by_name =
      for {:ok, snapshot} <- snapshots, into: %{}, do: {snapshot.group, snapshot}

    Enum.map(Config.caches(), fn group ->
      %{group: group, snapshot: Map.get(by_name, group.name)}
    end)
  end

  defp safe_purge(group) do
    CacheMaintenance.purge(group)
  rescue
    _ -> {:error, :maintenance_unavailable}
  catch
    _, _ -> {:error, :maintenance_unavailable}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="font-headline italic text-3xl text-on-surface">Runtime configuration</h1>
          <p class="mt-1 font-mono text-sm text-on-surface-variant">
            Declarations from omashiki.toml · reload applies the execution registry
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-4">
          <button
            type="button"
            phx-click="reload_config"
            phx-disable-with="Reloading…"
            class="border border-outline-variant px-4 py-2 font-label text-label-md uppercase tracking-[0.2em] text-on-surface hover:bg-surface-container-high"
          >
            Reload configuration
          </button>
          <p :if={@reload_result} class={["font-mono text-xs", reload_class(@reload_result)]}>
            {reload_message(@reload_result)}
          </p>
        </div>
      </header>
      <section class="border border-outline-variant bg-surface-container p-5">
        <header class="mb-5 flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
            Host limits
          </h2>
          <span class="font-mono text-xs text-on-surface-variant">{@max_containers} execution slots</span>
        </header>
        <dl class="grid gap-x-8 gap-y-3 sm:grid-cols-2 lg:grid-cols-4">
          <.limit label="CPU / container" value={format_limit(@limits.nano_cpus, " nano-cpu")} />
          <.limit label="Memory / container" value={format_bytes(@limits.memory_bytes)} />
          <.limit label="PID limit" value={@limits.pids_limit} />
          <.limit label="Swap" value={format_bytes(@limits.memory_swap_bytes)} />
        </dl>
      </section>

      <section class="border border-outline-variant bg-surface-container p-5">
        <header class="mb-5 flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
            Repositories
          </h2>
          <span class="font-mono text-xs text-on-surface-variant">{length(@repositories)} registered</span>
        </header>
        <div :if={@repositories == []} class="font-mono text-xs text-on-surface-variant">
          No repositories registered.
        </div>
        <div :if={@repositories != []} class="grid gap-4 md:grid-cols-2">
          <article :for={repo <- @repositories} class="border border-outline-variant/60 p-4">
            <h3 class="font-headline italic text-xl text-on-surface">{repo.name}</h3>
            <dl class="mt-4 grid gap-2 font-mono text-xs">
              <dt class="text-on-surface-variant">path</dt><dd class="break-all text-on-surface">
                {repo.path}
              </dd><dt class="text-on-surface-variant">base branch</dt><dd class="text-on-surface">
                {repo.base_branch}
              </dd>
            </dl>
          </article>
        </div>
      </section>

      <section class="border border-outline-variant bg-surface-container p-5">
        <header class="mb-5 flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
            Environments
          </h2>
          <span class="font-mono text-xs text-on-surface-variant">{length(@environments)} governed runtimes</span>
        </header>
        <div :if={@environments == []} class="font-mono text-xs text-on-surface-variant">
          No environments registered.
        </div>
        <div :if={@environments != []} class="grid gap-4 xl:grid-cols-2">
          <article :for={environment <- @environments} class="border border-outline-variant/60 p-4">
            <div class="flex flex-wrap items-baseline justify-between gap-3">
              <h3 class="font-headline italic text-xl text-on-surface">{environment.name}</h3><span class="font-mono text-xs text-status-succeeded">read-only</span>
            </div>
            <dl class="mt-4 grid gap-2 font-mono text-xs sm:grid-cols-[8rem_1fr]">
              <dt class="text-on-surface-variant">runtime</dt><dd class="text-on-surface">
                {environment.runtime.name}
              </dd>
              <dt class="text-on-surface-variant">handler</dt><dd class="text-on-surface">
                {environment.runtime.handler}
              </dd>
              <dt class="text-on-surface-variant">backend</dt><dd class="text-on-surface">
                {environment.runtime.backend}
              </dd>
              <dt class="text-on-surface-variant">distribution</dt><dd class="text-on-surface">
                {environment.runtime.distribution}
              </dd>
              <dt class="text-on-surface-variant">image</dt><dd class="break-all text-on-surface">
                {environment.runtime.image}
              </dd>
              <dt class="text-on-surface-variant">preset</dt><dd class="text-on-surface">
                {environment.preset.name}
              </dd>
              <dt class="text-on-surface-variant">network</dt><dd class="text-on-surface">
                {environment.network}
              </dd>
              <dt class="text-on-surface-variant">timeout</dt><dd class="text-on-surface">
                {environment.timeout_ms} ms
              </dd>
              <dt class="text-on-surface-variant">resources</dt><dd class="break-all text-on-surface">
                {Ops.json(environment.resources)}
              </dd>
            </dl>
          </article>
        </div>
      </section>

      <section class="border border-outline-variant bg-surface-container p-5">
        <header class="mb-5 flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
            Caches
          </h2>
          <span class="font-mono text-xs text-on-surface-variant">purge is blocked while leased</span>
        </header>
        <div :if={@cache_rows == []} class="font-mono text-xs text-on-surface-variant">
          No cache groups configured.
        </div>
        <div :if={@cache_rows != []} class="grid gap-4 md:grid-cols-2">
          <article :for={row <- @cache_rows} class="border border-outline-variant/60 p-4">
            <div class="flex flex-wrap items-baseline justify-between gap-3">
              <h3 class="font-headline italic text-xl text-on-surface">{row.group.name}</h3><span class="font-mono text-xs text-on-surface-variant">{if row.snapshot,
                do: "#{row.snapshot.active_leases} leases",
                else: "unavailable"}</span>
            </div>
            <p class="mt-3 font-mono text-xs text-on-surface-variant">
              {if row.snapshot,
                do: "#{format_bytes(row.snapshot.size_bytes)} used",
                else: "Snapshot unavailable"}
            </p>
            <button
              type="button"
              phx-click="purge_cache"
              phx-value-group={row.group.name}
              data-confirm="Purge this inactive cache group?"
              class="mt-4 border border-status-awaiting/50 px-3 py-2 font-label text-label-sm uppercase tracking-[0.2em] text-status-awaiting hover:border-status-awaiting"
            >Purge inactive group</button>
          </article>
        </div>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp limit(assigns) do
    ~H"""
    <div>
      <dt class="font-label text-label-sm uppercase tracking-[0.18em] text-on-surface-variant">
        {@label}
      </dt><dd class="mt-1 font-mono text-sm text-on-surface">{@value || "—"}</dd>
    </div>
    """
  end

  defp reload_message({:ok, :draining}),
    do: "Drain started; admission is paused until active attempts finish."

  defp reload_message({:ok, %{changed?: false, generation: generation}}),
    do: "Reloaded as generation #{generation}; the registry digest did not change."

  defp reload_message({:ok, %{changed?: true, generation: generation}}),
    do: "Applied generation #{generation}. Newly admitted jobs use it."

  defp reload_message({:error, :drain_in_progress}),
    do: "A rollout is already draining; wait for it to finish."

  defp reload_message({:error, reason}),
    do: "Reload rejected, previous configuration still serving: #{inspect_reason(reason)}"

  defp reload_message(_result), do: ""

  defp inspect_reason(reason) when is_binary(reason), do: reason
  defp inspect_reason(reason), do: inspect(reason)

  defp reload_class({:error, _reason}), do: "text-status-failed"
  defp reload_class(_result), do: "text-status-succeeded"

  defp format_limit(nil, _suffix), do: nil
  defp format_limit(value, suffix), do: "#{value}#{suffix}"

  defp format_bytes(nil), do: nil

  defp format_bytes(value) when is_integer(value) and value >= 1_073_741_824,
    do: "#{Float.round(value / 1_073_741_824, 1)} GiB"

  defp format_bytes(value) when is_integer(value) and value >= 1_048_576,
    do: "#{Float.round(value / 1_048_576, 1)} MiB"

  defp format_bytes(value) when is_integer(value), do: "#{value} B"
  defp format_bytes(_), do: nil
end
