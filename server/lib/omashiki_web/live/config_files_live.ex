defmodule OmashikiWeb.ConfigFilesLive do
  @moduledoc """
  Edit the house configuration and the task views file by name.

  Every read and write goes through `Omashiki.ConfigFiles`. Saving a draft
  only stores it. Saving the applied document or a piece, applying a draft and
  restoring a version of either rewrite the live file, so the screen validates
  first and asks for confirmation with the change summary.
  """

  use OmashikiWeb, :live_view

  alias Omashiki.ConfigFiles
  alias OmashikiWeb.AuthMode
  alias OmashikiWeb.Layouts
  alias OmashikiWeb.OperationHelpers, as: Ops

  @kinds [config: "House config", views: "Task views"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Omashiki · Config files")
     |> assign(:active_tab, :config)
     |> assign(:open_to_network?, AuthMode.open_to_network?())
     |> assign(:doc, nil)
     |> assign(:saved, nil)
     |> assign(:dirty?, false)
     |> assign(:drifted?, false)
     |> assign(:confirm, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = if params["kind"] == "views", do: :views, else: :config
    socket = assign(socket, :kind, kind)

    # Reading a document adopts an outside edit of the live file, so the
    # static render reads nothing: the connected one has to see the drift.
    if connected?(socket),
      do: {:noreply, load(socket, params["name"])},
      else: {:noreply, assign(socket, :listing, nil)}
  end

  defp load(socket, requested) do
    kind = socket.assigns.kind
    %{documents: documents} = listing = ConfigFiles.list(kind)
    name = requested || listing.applied || Enum.find_value(documents, & &1.name)
    doc = Enum.find(documents, &(&1.name == name))

    socket =
      socket
      |> assign(:listing, listing)
      |> assign(:drifted?, listing.drift?)
      |> assign(:creating?, false)
      |> assign(:create_error, nil)
      |> reset_outcome()

    cond do
      doc ->
        socket |> assign(:doc, doc) |> read_document()

      requested ->
        socket
        |> put_flash(:error, "No document named #{requested}.")
        |> push_patch(to: files_path(kind))

      true ->
        assign(socket, doc: nil, saved: nil, content: nil, dirty?: false, history: [])
    end
  end

  @impl true
  def handle_event("editor_changed", %{"content" => content}, socket),
    do: {:noreply, put_content(socket, content)}

  def handle_event("editor_save", %{"content" => content}, socket),
    do: {:noreply, socket |> put_content(content) |> save()}

  def handle_event("save", _params, socket), do: {:noreply, save(socket)}

  def handle_event("check", _params, socket) do
    %{kind: kind, doc: doc, content: content} = socket.assigns

    case ConfigFiles.validate(kind, content, doc.name) do
      {:ok, summary} -> {:noreply, socket |> reset_outcome() |> passed(summary)}
      {:error, message} -> {:noreply, socket |> reset_outcome() |> rejected(message)}
    end
  end

  def handle_event("apply", _params, %{assigns: %{dirty?: true}} = socket),
    do: {:noreply, put_flash(socket, :error, "Save the draft before applying it.")}

  def handle_event("apply", _params, socket) do
    %{kind: kind, doc: doc, saved: saved} = socket.assigns
    socket = reset_outcome(socket)

    case ConfigFiles.validate(kind, saved.content, doc.name) do
      {:ok, summary} ->
        {:noreply, confirm(socket, %{action: :apply, summary: summary})}

      {:error, message} ->
        {:noreply, rejected(socket, message)}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.history, &(&1.id == id)) do
      nil -> {:noreply, put_flash(socket, :error, "That version is no longer kept.")}
      version -> {:noreply, assign(socket, :confirm, %{action: :restore, version: version})}
    end
  end

  def handle_event("delete", _params, socket),
    do: {:noreply, assign(socket, :confirm, %{action: :delete})}

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("confirm", _params, %{assigns: %{confirm: confirm}} = socket)
      when is_map(confirm),
      do: {:noreply, socket |> assign(:confirm, nil) |> confirmed(confirm)}

  def handle_event("reload_document", _params, socket),
    do: {:noreply, socket |> reset_outcome() |> read_document()}

  def handle_event("new", _params, socket),
    do: {:noreply, assign(socket, creating?: !socket.assigns.creating?, create_error: nil)}

  def handle_event("create", %{"name" => name} = params, socket) do
    %{kind: kind, doc: doc, current_user: user} = socket.assigns
    from = if params["from"] == "copy" and doc, do: doc.name, else: :blank

    case ConfigFiles.create(kind, String.trim(name), from: from, author: user) do
      {:ok, created} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created #{created.name}.")
         |> push_patch(to: files_path(kind, created.name))}

      {:error, reason} ->
        {:noreply, assign(socket, :create_error, create_message(reason))}
    end
  end

  defp confirmed(socket, %{action: :save, content: content}), do: write(socket, content)

  defp confirmed(socket, %{action: :apply}) do
    %{kind: kind, doc: doc, current_user: user} = socket.assigns

    case ConfigFiles.apply(kind, doc.name, author: user) do
      {:ok, %{document: document, reload: reload}} ->
        socket
        |> put_flash(:info, "Applied #{document.name}.")
        |> assign(:doc, document)
        |> assign(:reload_result, reload)
        |> refresh()

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp confirmed(socket, %{action: :restore, version: version}) do
    %{kind: kind, doc: doc, saved: saved, current_user: user} = socket.assigns

    case ConfigFiles.restore(kind, doc.name, version.id, saved.hash, author: user) do
      {:ok, %{reload: reload}} ->
        socket
        |> put_flash(:info, "Restored the version #{Ops.short_id(version.hash)}.")
        |> assign(:reload_result, reload)
        |> read_document()

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp confirmed(socket, %{action: :delete}) do
    %{kind: kind, doc: doc, current_user: user} = socket.assigns

    case ConfigFiles.delete(kind, doc.name, author: user) do
      :ok ->
        socket
        |> put_flash(:info, "Deleted #{doc.name}.")
        |> push_patch(to: files_path(kind))

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  # A file the house loads is validated and confirmed before it is written; a
  # draft is only stored, valid or not.
  defp save(socket) do
    %{kind: kind, doc: doc, content: content} = socket.assigns
    socket = reset_outcome(socket)

    if live?(doc) do
      case ConfigFiles.validate(kind, content, doc.name) do
        {:ok, summary} ->
          confirm(socket, %{action: :save, content: content, summary: summary})

        {:error, message} ->
          rejected(socket, message)
      end
    else
      write(socket, content)
    end
  end

  defp write(socket, content) do
    %{kind: kind, doc: doc, saved: saved, current_user: user} = socket.assigns

    case ConfigFiles.save(kind, doc.name, content, saved.hash, author: user) do
      {:ok, %{document: document, reload: reload}} ->
        socket
        |> put_flash(:info, "Saved #{document.name}.")
        |> assign(:doc, document)
        |> assign(:saved, %{content: content, hash: document.hash})
        |> put_content(socket.assigns.content)
        |> assign(:reload_result, reload)
        |> push_event("editor_diagnostics", %{items: []})
        |> refresh()

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp failed(socket, {:invalid, message}), do: rejected(socket, message)

  defp failed(socket, reason) when reason in [:changed, :changed_on_disk],
    do: assign(socket, :conflict?, true)

  # The directory stopped accepting writes after the page listed it.
  defp failed(socket, {:read_only, _dir} = reason),
    do: socket |> put_flash(:error, failure_message(reason)) |> refresh()

  defp failed(socket, reason), do: put_flash(socket, :error, failure_message(reason))

  defp passed(socket, summary) do
    socket
    |> assign(:check, {:ok, summary})
    |> push_event("editor_diagnostics", %{items: []})
  end

  defp confirm(socket, confirm) do
    socket
    |> assign(:confirm, confirm)
    |> push_event("editor_diagnostics", %{items: []})
  end

  defp rejected(socket, message) do
    %{kind: kind, doc: doc} = socket.assigns

    items =
      for line <- ConfigFiles.error_lines(kind, doc.name, message),
          do: %{line: line, message: message}

    socket
    |> assign(:check, {:error, message})
    |> push_event("editor_diagnostics", %{items: items})
  end

  defp reset_outcome(socket),
    do: assign(socket, check: nil, confirm: nil, conflict?: false, reload_result: nil)

  # Opens the selected document. The editor reads its first content from the
  # page; once it is on screen, new content goes to it as an event.
  defp read_document(socket) do
    %{kind: kind, doc: doc} = socket.assigns

    case ConfigFiles.read(kind, doc.name) do
      {:ok, saved} ->
        socket =
          if socket.assigns.saved,
            do:
              push_event(socket, "editor_set", %{
                content: saved.content,
                readonly: read_only?(socket.assigns)
              }),
            else: socket

        socket
        |> assign(:saved, saved)
        |> put_content(saved.content)
        |> refresh()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "#{doc.name} no longer exists.")
        |> push_patch(to: files_path(kind))
    end
  end

  defp put_content(socket, content),
    do: assign(socket, content: content, dirty?: content != socket.assigns.saved.content)

  defp refresh(socket) do
    %{kind: kind, doc: doc} = socket.assigns
    listing = ConfigFiles.list(kind)

    socket
    |> assign(:listing, listing)
    |> assign(:doc, Enum.find(listing.documents, doc, &(&1.name == doc.name)))
    |> assign(:history, ConfigFiles.history(kind, doc.name))
  end

  defp live?(doc), do: doc.applied? or doc.piece?

  defp read_only?(%{listing: listing}), do: listing.read_only != nil

  defp files_path(kind, name \\ nil) do
    params = Enum.reject([kind: kind, name: name], fn {_key, value} -> is_nil(value) end)
    ~p"/config/files?#{params}"
  end

  defp create_message(:invalid_name),
    do: "Use up to 40 lowercase letters, digits, - and _, starting with a letter or digit."

  defp create_message(:exists), do: "A document with that name already exists."
  defp create_message(:not_found), do: "The document to copy no longer exists."
  defp create_message(reason), do: failure_message(reason)

  defp failure_message(:not_found), do: "That document no longer exists."
  defp failure_message(:applied), do: "The applied document cannot be deleted."

  defp failure_message(:piece),
    do: "An include piece is edited in place; it cannot be applied or deleted."

  defp failure_message({:read_only, dir}), do: "#{dir} is not writable."

  defp failure_message(:unsafe_path),
    do: "Omashiki writes only inside the file's own directory, never through a symlink."

  defp failure_message(reason) when is_atom(reason),
    do: "The file could not be written: #{:file.format_error(reason)}."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6 py-2">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="font-headline italic text-3xl text-on-surface">Configuration files</h1>
          <p class="mt-1 font-mono text-sm text-on-surface-variant">
            Named copies of each file · the applied one is the file the house reads
          </p>
        </div>
        <.link navigate={~p"/config"} class={action_class(:neutral)}>Runtime configuration</.link>
      </header>

      <.alert_banner :if={@open_to_network?} kind={:warning}>
        <:title>Anyone who reaches this house can edit it</:title>
        Login is off and the server listens beyond loopback, so every peer that reaches it can change its configuration here.
      </.alert_banner>

      <nav
        aria-label="File kinds"
        class="flex flex-wrap gap-x-6 gap-y-3 border-b border-outline-variant pb-3"
      >
        <.link
          :for={{kind, label} <- kinds()}
          patch={files_path(kind)}
          class={Layouts.nav_link_class(kind, %{active_tab: @kind})}
          aria-current={if kind == @kind, do: "page", else: nil}
          data-confirm={@dirty? && "Discard unsaved changes?"}
        >
          {label}
        </.link>
      </nav>

      <.alert_banner :if={@drifted?} kind={:warning}>
        <:title>Edited outside Omashiki</:title>
        The live file changed on disk. That edit is now the applied document; the content it replaced is in its history.
      </.alert_banner>

      <p :if={is_nil(@listing)} class="font-mono text-xs text-status-awaiting">connecting…</p>

      <.alert_banner :if={@listing && @listing.read_only} kind={:warning}>
        <:title>Read-only</:title>
        {@listing.read_only} is not writable, so this page can only show the files. In a container, mount the config directory writable.
      </.alert_banner>

      <div :if={@listing} class="grid gap-6 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <section class="flex flex-col gap-4 self-start border border-outline-variant bg-surface-container p-5">
          <header class="flex items-baseline justify-between gap-3">
            <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
              Documents
            </h2>
            <button
              type="button"
              phx-click="new"
              disabled={read_only?(assigns)}
              class={action_class(:neutral)}
            >
              New
            </button>
          </header>

          <form
            :if={@creating?}
            id="new-document"
            phx-submit="create"
            class="flex flex-col gap-3 border-t border-outline-variant/40 pt-4"
          >
            <label class="font-mono text-xs text-on-surface-variant">
              name <.text_input name="name" kind={:mono} required maxlength="40" autofocus />
            </label>
            <p :if={@create_error} class="font-mono text-xs text-status-failed">{@create_error}</p>
            <fieldset class="flex flex-col gap-2 font-mono text-xs text-on-surface">
              <label class="flex items-center gap-2">
                <input type="radio" name="from" value="blank" checked={is_nil(@doc)} /> blank
              </label>
              <label :if={@doc} class="flex items-center gap-2">
                <input type="radio" name="from" value="copy" checked /> copy of {@doc.name}
              </label>
            </fieldset>
            <button type="submit" class={action_class(:neutral)}>Create</button>
          </form>

          <p :if={@listing.documents == []} class="font-mono text-xs text-on-surface-variant">
            No {kind_file(@kind)} yet. Create a document and apply it.
          </p>
          <ul class="flex flex-col gap-1">
            <li :for={doc <- Enum.reject(@listing.documents, & &1.piece?)}>
              <.document_link doc={doc} selected={@doc} kind={@kind} dirty?={@dirty?} />
              <ul :if={doc.applied?} class="ml-4 border-l border-outline-variant/60 pl-2">
                <li :for={piece <- Enum.filter(@listing.documents, & &1.piece?)}>
                  <.document_link doc={piece} selected={@doc} kind={@kind} dirty?={@dirty?} />
                </li>
              </ul>
            </li>
          </ul>
        </section>

        <section :if={@doc} class="flex min-w-0 flex-col gap-4">
          <header class="flex flex-wrap items-end justify-between gap-4">
            <div class="min-w-0">
              <h2 class="font-headline italic text-2xl text-on-surface">
                {@doc.name}
                <span
                  :if={@doc.applied?}
                  class="ml-2 font-mono text-xs not-italic text-status-success"
                >
                  applied
                </span>
                <span
                  :if={@doc.piece?}
                  class="ml-2 font-mono text-xs not-italic text-on-surface-variant"
                >
                  include piece
                </span>
              </h2>
              <p class="mt-1 break-all font-mono text-xs text-on-surface-variant">
                {@doc.path}
                <span :if={@dirty?} class="text-status-awaiting">· unsaved changes</span>
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button type="button" phx-click="check" class={action_class(:neutral)}>Check</button>
              <button
                type="button"
                phx-click="save"
                disabled={read_only?(assigns)}
                class={action_class(:neutral)}
              >
                Save
              </button>
              <button
                :if={not live?(@doc)}
                type="button"
                phx-click="apply"
                disabled={@dirty? or read_only?(assigns)}
                title={@dirty? && "Save the draft before applying it"}
                class={action_class(:primary)}
              >
                Apply
              </button>
              <button
                :if={not live?(@doc)}
                type="button"
                phx-click="delete"
                disabled={read_only?(assigns)}
                class={action_class(:danger)}
              >
                Delete
              </button>
            </div>
          </header>

          <p class="font-mono text-xs text-on-surface-variant">
            {save_note(@doc)} Ctrl/Cmd-S saves.
          </p>

          <.alert_banner :if={@conflict?} kind={:warning}>
            <:title>Changed elsewhere</:title>
            This file changed since you opened it. Nothing was written. Reload it to see the current content; your edits are replaced.
            <:actions>
              <button type="button" phx-click="reload_document" class={action_class(:neutral)}>
                Reload
              </button>
            </:actions>
          </.alert_banner>

          <.check_result :if={@check} check={@check} />

          <p
            :if={@reload_result}
            id="reload-result"
            class={["font-mono text-xs", Ops.reload_class(@reload_result)]}
          >
            {Ops.reload_message(@reload_result)}
          </p>

          <div
            id="toml-editor"
            phx-hook="TomlEditor"
            phx-update="ignore"
            data-content={@saved.content}
            data-readonly={to_string(read_only?(assigns))}
            class="h-[60vh] min-h-[20rem] border border-outline-variant"
          >
          </div>

          <section class="border border-outline-variant bg-surface-container p-5">
            <header class="mb-4 flex flex-wrap items-baseline justify-between gap-3">
              <h2 class="font-label text-label-md tracking-[0.25em] uppercase text-on-surface-variant">
                History
              </h2>
              <span class="font-mono text-xs text-on-surface-variant">
                earlier versions, newest first
              </span>
            </header>
            <p :if={@history == []} class="font-mono text-xs text-on-surface-variant">
              No earlier versions.
            </p>
            <table :if={@history != []} id="history" class="w-full font-mono text-xs">
              <thead class="text-left text-on-surface-variant">
                <tr>
                  <th class="py-2 pr-4 font-normal">version</th>
                  <th class="py-2 pr-4 font-normal">replaced</th>
                  <th class="py-2 pr-4 font-normal">by</th>
                  <th class="py-2 font-normal"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-outline-variant/40 text-on-surface">
                <tr :for={version <- @history} id={"version-#{version.id}"}>
                  <td class="py-2 pr-4">{Ops.short_id(version.hash)}</td>
                  <td class="py-2 pr-4">{Ops.timestamp(version.at)}</td>
                  <td class="py-2 pr-4">{version.author || "an outside edit"}</td>
                  <td class="py-2 text-right">
                    <button
                      type="button"
                      phx-click="restore"
                      disabled={read_only?(assigns)}
                      phx-value-id={version.id}
                      class={action_class(:neutral)}
                    >
                      Restore
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>
        </section>
      </div>

      <div
        :if={@confirm}
        id="confirm"
        class="fixed inset-0 z-40 flex items-center justify-center p-4"
        phx-window-keydown="cancel_confirm"
        phx-key="escape"
      >
        <div class="absolute inset-0 bg-scrim/60" phx-click="cancel_confirm" aria-hidden="true"></div>
        <section
          role="dialog"
          aria-modal="true"
          aria-labelledby="confirm-title"
          class="relative flex max-h-full w-full max-w-xl flex-col gap-4 overflow-y-auto border border-outline-variant bg-surface-container-low p-6"
        >
          <h2 id="confirm-title" class="font-headline italic text-2xl text-on-surface">
            {confirm_title(@confirm, @doc)}
          </h2>
          <p class="font-mono text-sm text-on-surface-variant">
            {confirm_body(@confirm, @doc, @kind)}
          </p>
          <p
            :if={@confirm.action == :restore and @dirty?}
            class="font-mono text-sm text-status-awaiting"
          >
            Unsaved edits are discarded.
          </p>
          <.summary :if={@confirm[:summary]} summary={@confirm.summary} />
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_confirm" class={action_class(:neutral)}>
              Cancel
            </button>
            <button
              type="button"
              phx-click="confirm"
              class={action_class(if @confirm.action == :delete, do: :danger, else: :primary)}
            >
              {confirm_label(@confirm)}
            </button>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :doc, :map, required: true
  attr :selected, :map, required: true
  attr :kind, :atom, required: true
  attr :dirty?, :boolean, required: true

  defp document_link(assigns) do
    ~H"""
    <.link
      patch={files_path(@kind, @doc.name)}
      id={"document-#{@doc.name}"}
      data-confirm={@dirty? && @doc.name != @selected.name && "Discard unsaved changes?"}
      aria-current={if @doc.name == @selected.name, do: "page", else: nil}
      class={[
        "flex items-baseline justify-between gap-3 px-2 py-1.5 font-mono text-xs transition-colors hover:bg-surface-container-high",
        if(@doc.name == @selected.name,
          do: "bg-surface-container-high text-primary-container",
          else: "text-on-surface"
        )
      ]}
    >
      <span class="min-w-0 break-all">
        {@doc.name}<span :if={@doc.applied?} class="ml-2 text-status-success">applied</span>
      </span>
      <span class="shrink-0 text-on-surface-variant">{Ops.age(@doc.updated_at)}</span>
    </.link>
    """
  end

  attr :check, :any, required: true

  defp check_result(%{check: {:error, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <.alert_banner kind={:error}>
      <:title>Rejected</:title>
      <pre class="whitespace-pre-wrap break-words font-mono text-xs">{@message}</pre>
    </.alert_banner>
    """
  end

  defp check_result(%{check: {:ok, summary}} = assigns) do
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div class="flex flex-col gap-3">
      <.alert_banner kind={:success}>The file is valid.</.alert_banner>
      <.summary summary={@summary} />
    </div>
    """
  end

  attr :summary, :map, required: true

  defp summary(assigns) do
    assigns = assign(assigns, :changes, changes(assigns.summary))

    ~H"""
    <ul :if={@changes != []} id="change-summary" class="flex flex-col gap-1 font-mono text-xs">
      <li :for={{section, text} <- @changes}>
        <span class="text-on-surface-variant">{section}</span>
        <span class="text-on-surface">{text}</span>
      </li>
    </ul>
    <p
      :if={@changes == [] and Map.has_key?(@summary, :restart_required)}
      class="font-mono text-xs text-on-surface-variant"
    >
      No declared entry changes.
    </p>
    <.alert_banner :if={@summary[:restart_required] not in [nil, []]} kind={:warning}>
      <:title>Restart required</:title>
      A reload does not apply {Enum.map_join(@summary.restart_required, ", ", &"[#{&1}]")}. The file is still written; restart the house for those sections to take effect.
    </.alert_banner>
    """
  end

  # "environments: added a · changed b" per declared section that changes.
  defp changes(summary) do
    for {section, %{added: added, removed: removed, changed: changed}} <- Enum.sort(summary),
        parts =
          for(
            {label, [_ | _] = names} <- [added: added, removed: removed, changed: changed],
            do: "#{label} #{Enum.join(names, ", ")}"
          ),
        parts != [],
        do: {section, Enum.join(parts, " · ")}
  end

  defp kinds, do: @kinds

  defp kind_file(:config), do: "house configuration"
  defp kind_file(:views), do: "task views file"

  defp save_note(%{applied?: true}), do: "Saving writes the live file and applies it."
  defp save_note(%{piece?: true}), do: "Saving writes this piece and applies it."
  defp save_note(_doc), do: "A draft: saving stores it, even when invalid. Apply makes it live."

  defp confirm_title(%{action: :save}, doc), do: "Save and apply #{doc.name}?"
  defp confirm_title(%{action: :apply}, doc), do: "Apply #{doc.name}?"

  defp confirm_title(%{action: :restore, version: version}, _doc),
    do: "Restore version #{Ops.short_id(version.hash)}?"

  defp confirm_title(%{action: :delete}, doc), do: "Delete #{doc.name}?"

  defp confirm_body(%{action: :save}, _doc, kind),
    do: "The live file is rewritten. #{takes_effect(kind)}"

  defp confirm_body(%{action: :apply}, _doc, kind),
    do:
      "It replaces the live file, which keeps its current content in history. #{takes_effect(kind)}"

  defp confirm_body(%{action: :restore, version: version}, doc, kind) do
    "Put back the content replaced at #{Ops.timestamp(version.at)}. The current content stays in history." <>
      if live?(doc), do: " The live file is rewritten. #{takes_effect(kind)}", else: ""
  end

  defp confirm_body(%{action: :delete}, _doc, _kind),
    do: "The draft and its history are removed. This cannot be undone."

  defp takes_effect(:config), do: "The house reloads it now."
  defp takes_effect(:views), do: "The Home screen shows it within seconds."

  defp confirm_label(%{action: :save}), do: "Save and apply"
  defp confirm_label(%{action: :apply}), do: "Apply"
  defp confirm_label(%{action: :restore}), do: "Restore"
  defp confirm_label(%{action: :delete}), do: "Delete"

  defp action_class(tone) do
    [
      "border px-3 py-2 font-label text-label-sm uppercase tracking-[0.2em] transition-colors disabled:cursor-not-allowed disabled:opacity-30",
      case tone do
        :neutral ->
          "border-outline-variant text-on-surface hover:bg-surface-container-high"

        :primary ->
          "border-primary-container/60 text-primary-container hover:border-primary-container"

        :danger ->
          "border-status-failed/50 text-status-failed hover:border-status-failed"
      end
    ]
  end
end
