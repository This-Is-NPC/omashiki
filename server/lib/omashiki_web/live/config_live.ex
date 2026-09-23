defmodule OmashikiWeb.ConfigLive do
  @moduledoc "Repository, environment, runtime, cache, and API token operations."

  use OmashikiWeb, :live_view

  alias Omashiki.ApiTokens
  alias Omashiki.ApiTokens.{Audit, Token}
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
     |> assign(:issued_token, nil)
     |> assign_config()
     |> assign_tokens()}
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

  def handle_event("create_token", %{"token" => params}, socket) do
    attrs = %{
      name: params["name"],
      scopes: Map.get(params, "scopes", []),
      allowed_environments:
        params
        |> Map.get("environments", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1),
      max_active_jobs: integer(params["max_active_jobs"]),
      ttl_days: integer(params["ttl_days"])
    }

    case ApiTokens.create_for_user(socket.assigns.current_user, attrs) do
      {:ok, token, plaintext} ->
        Audit.record(token, "issue")

        {:noreply,
         socket
         |> assign(:issued_token, %{name: token.name, plaintext: plaintext})
         |> assign_tokens()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:issued_token, nil)
         |> put_flash(:error, "Token not created: #{ApiTokens.format_error(reason)}.")}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) when is_binary(id) do
    socket = assign(socket, :issued_token, nil)

    case ApiTokens.revoke(socket.assigns.current_user, id) do
      {:ok, token} ->
        {:noreply, socket |> put_flash(:info, "Revoked token #{token.name}.") |> assign_tokens()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No such token to revoke.")}
    end
  end

  defp assign_config(socket) do
    socket
    |> assign(:repositories, Config.repositories())
    |> assign(:environments, Config.environments())
    |> assign(:limits, HostSettings.get_limits())
    |> assign(:max_containers, HostSettings.get_max_concurrent_containers())
    |> assign(:cache_rows, cache_rows())
  end

  defp assign_tokens(socket),
    do: assign(socket, :tokens, ApiTokens.list_for_user(socket.assigns.current_user))

  # A blank or non-numeric field reaches ApiTokens as-is, so its validation
  # decides the message rather than a second check here.
  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp integer(value), do: value

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
          <.link
            navigate={~p"/config/files"}
            class="border border-outline-variant px-4 py-2 font-label text-label-md uppercase tracking-[0.2em] text-on-surface hover:bg-surface-container-high"
          >
            Edit files
          </.link>
          <button
            type="button"
            phx-click="reload_config"
            phx-disable-with="Reloading…"
            class="border border-outline-variant px-4 py-2 font-label text-label-md uppercase tracking-[0.2em] text-on-surface hover:bg-surface-container-high"
          >
            Reload configuration
          </button>
          <p :if={@reload_result} class={["font-mono text-xs", Ops.reload_class(@reload_result)]}>
            {Ops.reload_message(@reload_result)}
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

      <section class="border border-outline-variant bg-surface-container p-5">
        <header class="mb-5 flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
            Tokens
          </h2>
          <span class="font-mono text-xs text-on-surface-variant">{length(@tokens)} issued to {@current_user.username}</span>
        </header>
        <div
          :if={@issued_token}
          id="issued-token"
          class="mb-5 border border-status-succeeded/50 p-4 font-mono text-xs"
        >
          <p class="text-on-surface-variant">
            Copy {@issued_token.name} now. It is not shown again.
          </p>
          <p class="mt-2 break-all text-on-surface">{@issued_token.plaintext}</p>
        </div>
        <div :if={@tokens == []} class="font-mono text-xs text-on-surface-variant">
          No tokens issued.
        </div>
        <table :if={@tokens != []} class="w-full font-mono text-xs">
          <thead class="text-left text-on-surface-variant">
            <tr>
              <th class="py-2 pr-4 font-normal">name</th>
              <th class="py-2 pr-4 font-normal">scopes</th>
              <th class="py-2 pr-4 font-normal">environments</th>
              <th class="py-2 pr-4 font-normal">expires</th>
              <th class="py-2 pr-4 font-normal">webhook</th>
              <th class="py-2 font-normal"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant/40 text-on-surface">
            <tr :for={token <- @tokens} id={"token-#{token.id}"}>
              <td class="py-2 pr-4">{token.name}</td>
              <td class="py-2 pr-4">{Enum.join(token.scopes, ", ")}</td>
              <td class="py-2 pr-4">{Enum.join(token.allowed_environments, ", ")}</td>
              <td class="py-2 pr-4">{token_expiry(token)}</td>
              <td class="py-2 pr-4">{if token.webhook_destination, do: "set", else: "not set"}</td>
              <td class="py-2 text-right">
                <button
                  :if={Token.status(token) == :active}
                  type="button"
                  phx-click="revoke_token"
                  phx-value-id={token.id}
                  data-confirm="Revoke this token? Clients using it stop working."
                  class="border border-status-failed/50 px-3 py-1 font-label text-label-sm uppercase tracking-[0.2em] text-status-failed hover:border-status-failed"
                >Revoke</button>
              </td>
            </tr>
          </tbody>
        </table>
        <form
          id="create-token"
          phx-submit="create_token"
          class="mt-6 grid gap-4 border-t border-outline-variant/40 pt-5 md:grid-cols-2"
        >
          <label class="font-mono text-xs text-on-surface-variant">
            name <.text_input name="token[name]" kind={:mono} required maxlength="80" />
          </label>
          <label class="font-mono text-xs text-on-surface-variant">
            environments, comma-separated or *
            <.text_input name="token[environments]" kind={:mono} required placeholder="*" />
          </label>
          <label class="font-mono text-xs text-on-surface-variant">
            max active jobs
            <.text_input name="token[max_active_jobs]" type="number" kind={:mono} value="10" min="1" />
          </label>
          <label class="font-mono text-xs text-on-surface-variant">
            days until expiry
            <.text_input name="token[ttl_days]" type="number" kind={:mono} value="30" min="1" />
          </label>
          <fieldset class="flex flex-wrap gap-4 font-mono text-xs text-on-surface">
            <label :for={scope <- Token.allowed_scopes()} class="flex items-center gap-2">
              <input type="checkbox" name="token[scopes][]" value={scope} checked={scope != "cancel"} />
              {scope}
            </label>
          </fieldset>
          <div class="flex items-end justify-end">
            <button
              type="submit"
              phx-disable-with="Creating…"
              class="border border-outline-variant px-4 py-2 font-label text-label-md uppercase tracking-[0.2em] text-on-surface hover:bg-surface-container-high"
            >
              Create token
            </button>
          </div>
        </form>
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

  defp token_expiry(token) do
    case Token.status(token) do
      :active -> Ops.timestamp(token.expires_at)
      status -> Ops.status_label(status)
    end
  end

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
