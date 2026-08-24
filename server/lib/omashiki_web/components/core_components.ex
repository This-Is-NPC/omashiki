defmodule OmashikiWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as modals, tables, and
  forms. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The default components use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn
  how to customize them or feel free to swap in another framework altogether.

  Icons are provided by [heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true, doc: "DOM id for the dialog root and focus wrap."
  attr :show, :boolean, default: false, doc: "When true, opens on mount via show_modal/1."
  attr :on_cancel, JS, default: %JS{}, doc: "JS command run on escape, click-away, or close."
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-bg"} class="bg-zinc-50/90 fixed inset-0 transition-opacity" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="shadow-zinc-700/10 ring-zinc-700/10 relative hidden rounded-2xl bg-white p-14 shadow-lg ring-1 transition"
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-20 hover:opacity-40"
                  aria-label="close"
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "Flash root id; defaults to flash-<kind>."
  attr :flash, :map, default: %{}, doc: "LiveView flash map; message looked up by kind."
  attr :title, :string, default: nil, doc: "Optional bold title above the body copy."
  attr :kind, :atom, values: [:info, :error], doc: ":info or :error — tone and flash key."
  attr :rest, :global, doc: "Passthrough HTML attrs on the alert container."

  slot :inner_block, doc: "Inline message; wins over flash[kind] when present."

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 w-80 sm:w-96 z-50 p-4 border font-body text-sm bg-surface-container-high text-on-surface",
        @kind == :info && "border-primary-container",
        @kind == :error && "border-status-failed/70"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
        {@title}
      </p>
      <p class="mt-2 text-sm leading-5">{msg}</p>
      <button type="button" class="group absolute top-1 right-1 p-2" aria-label="close">
        <.icon name="hero-x-mark-solid" class="h-5 w-5 opacity-40 group-hover:opacity-70" />
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map,
    required: true,
    doc: "LiveView flash map shared by info/error/client/server flashes."

  attr :id, :string, default: "flash-group", doc: "Wrapper id for the stacked flash region."

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title="Success!" flash={@flash} />
      <.flash kind={:error} title="Error!" flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {"Attempting to reconnect"}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {"Hang in there while we get back on track"}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "Form data — changeset, map, or to_form/1 result."
  attr :as, :any, default: nil, doc: "Param namespace for nested form params (form :as)."

  attr :rest, :global,
    doc: "Passthrough HTML attrs on the <form> tag.",
    include: ~w(autocomplete name rel action enctype method novalidate target multipart)

  slot :inner_block, required: true
  slot :actions, doc: "Footer actions (submit/cancel); receives the form as slot arg."

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="mt-10 space-y-8 bg-white">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Omashiki-themed button. Sharp corners, uppercase label text, neon-green
  primary fill that matches the visual identity defined in `tokens.css`.

  Variants:

    * `:primary` (default) — neon `bg-primary-container` fill on
      `text-surface`. The "do the thing" action.
    * `:secondary` — outlined `border-on-surface-variant` chip.
    * `:ghost` — outlined chip that picks up `primary-container` on hover.
      The default for navigation actions.
    * `:danger` — outlined chip rendered in `status-failed` (Omashiki red).

  Pass `class` to extend (e.g. `class="w-full"`); the variant base classes
  are concatenated first so caller overrides win on cascade.

  ## Examples

      <.button>Send!</.button>
      <.button kind={:danger} phx-click="delete">Delete</.button>
      <.button kind={:secondary} class="w-full">Cancel</.button>
  """
  attr :type, :string,
    default: nil,
    doc: "Native button type (submit/button); nil omits the attr."

  attr :kind, :atom,
    doc: "Visual variant — primary fill, secondary/ghost outline, danger failed tone.",
    default: :primary,
    values: [:primary, :secondary, :ghost, :danger]

  attr :class, :any, default: nil, doc: "Extra classes after the variant base (e.g. w-full)."

  attr :rest, :global,
    doc: "Passthrough HTML/phx attrs on the <button>.",
    include: ~w(disabled form name value phx-click phx-value-id phx-disable-with data-confirm)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "font-label text-label-xl uppercase tracking-widest px-6 py-3 transition-colors disabled:opacity-30 disabled:cursor-not-allowed phx-submit-loading:opacity-75",
        button_kind_class(@kind),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_kind_class(:primary),
    do: "text-surface bg-primary-container hover:bg-primary-fixed-dim border border-transparent"

  defp button_kind_class(:secondary),
    do:
      "text-on-surface-variant border border-outline-variant hover:border-on-surface-variant hover:text-on-surface"

  defp button_kind_class(:ghost),
    do:
      "text-on-surface-variant border border-outline-variant hover:border-primary-container hover:text-primary-container"

  defp button_kind_class(:danger),
    do:
      "text-status-failed border border-status-failed/60 hover:border-status-failed hover:bg-status-failed/10"

  @doc """
  Themed text input. Wraps the native `<input>` with the standard Omashiki
  border + on-surface text colour so callers don't reproduce the same
  string. Pass `kind={:mono}` to switch the type face to `font-mono`.

  ## Example

      <.text_input name="token" type="password" placeholder="Bearer token" />
      <.text_input field={@form[:slug]} kind={:mono} />
  """
  attr :id, :any, default: nil, doc: "Input id; taken from field when omitted."
  attr :name, :any, default: nil, doc: "Input name; taken from field when omitted."
  attr :value, :any, default: nil, doc: "Current value; taken from field when omitted."
  attr :type, :string, default: "text", doc: "Native input type (text, password, …)."

  attr :kind, :atom,
    doc: ":mono switches the typeface to font-mono (tokens, paths).",
    default: :default,
    values: [:default, :mono]

  attr :class, :any, default: nil, doc: "Extra classes on the <input>."

  attr :field, Phoenix.HTML.FormField,
    default: nil,
    doc: "FormField — fills id/name/value when set."

  attr :rest, :global,
    doc: "Passthrough HTML attrs on the <input>.",
    include: ~w(autocomplete autofocus disabled max maxlength min minlength
                pattern placeholder readonly required step list)

  def text_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    # `attr default: nil` puts the key in the map already, so `assign_new`
    # would skip the field-derived value. Pull the field's id/name/value
    # only when the caller did not pass an explicit override (which is
    # the documented overrideability contract).
    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns[:id] || field.id)
    |> assign(:name, assigns[:name] || field.name)
    |> assign(
      :value,
      assigns[:value] || Phoenix.HTML.Form.normalize_value(assigns.type, field.value)
    )
    |> text_input()
  end

  def text_input(assigns) do
    ~H"""
    <input
      type={@type}
      id={@id}
      name={@name}
      value={@value}
      class={[
        "w-full bg-surface-container-low border border-outline-variant px-3 py-2 text-sm text-on-surface placeholder:text-on-surface-variant/60 focus:border-primary-container focus:outline-none transition-colors",
        @kind == :mono && "font-mono",
        @class
      ]}
      {@rest}
    />
    """
  end

  @doc """
  Inline alert / banner. Replaces the half-dozen hand-rolled
  status-tinted blocks scattered across LiveViews and the login template.

  ## Variants

    * `:error`   — `status-failed` (Omashiki red)
    * `:warning` — `status-awaiting` (amber)
    * `:info`    — `status-running` (sky)
    * `:success` — `status-success` (neon green)

  Use the optional `:title` slot for an uppercase eyebrow above the body.
  Use `:actions` for trailing buttons / links.

  ## Example

      <.alert_banner kind={:error}>That token is not valid.</.alert_banner>

      <.alert_banner kind={:warning}>
        <:title>Awaiting human</:title>
        Resolver requested a checkpoint.
        <:actions>
          <.link navigate={~p"/"}>Configure</.link>
        </:actions>
      </.alert_banner>
  """
  attr :kind, :atom,
    doc: "Tone — failed/awaiting/running/success token colours.",
    default: :info,
    values: [:error, :warning, :info, :success]

  attr :class, :any, default: nil, doc: "Extra classes on the banner root."
  slot :title, doc: "Optional uppercase eyebrow above the body."
  slot :actions, doc: "Trailing actions (links/buttons) on the right."
  slot :inner_block, required: true

  def alert_banner(assigns) do
    ~H"""
    <div class={[
      "border px-4 py-3 flex items-start justify-between gap-4 font-mono text-sm",
      alert_kind_class(@kind),
      @class
    ]}>
      <div class="flex-1 min-w-0">
        <p
          :if={@title != []}
          class={[
            "font-label text-label-md tracking-[0.3em] uppercase mb-1",
            alert_title_class(@kind)
          ]}
        >
          {render_slot(@title)}
        </p>
        <div class={alert_body_class(@kind)}>
          {render_slot(@inner_block)}
        </div>
      </div>
      <div :if={@actions != []} class="flex items-center gap-3 shrink-0">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  defp alert_kind_class(:error), do: "bg-status-failed/10 border-status-failed/40"
  defp alert_kind_class(:warning), do: "bg-status-awaiting/10 border-status-awaiting/40"
  defp alert_kind_class(:info), do: "bg-status-running/10 border-status-running/40"
  defp alert_kind_class(:success), do: "bg-status-success/10 border-status-success/40"

  defp alert_title_class(:error), do: "text-status-failed"
  defp alert_title_class(:warning), do: "text-status-awaiting"
  defp alert_title_class(:info), do: "text-status-running"
  defp alert_title_class(:success), do: "text-status-success"

  defp alert_body_class(:error), do: "text-status-failed"
  defp alert_body_class(:warning), do: "text-status-awaiting"
  defp alert_body_class(:info), do: "text-status-running"
  defp alert_body_class(:success), do: "text-status-success"

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil, doc: "Control id; taken from field when omitted."
  attr :name, :any, doc: "Control name; taken from field when omitted."
  attr :label, :string, default: nil, doc: "Visible label above (or beside) the control."
  attr :value, :any, doc: "Current value; taken from field when omitted."

  attr :type, :string,
    doc: "Control type — select/checkbox/textarea take dedicated branches.",
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               range search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "FormField — fills id/name/value and translates field errors."

  attr :errors, :list,
    default: [],
    doc: "Error strings under the control (field errors when using field:)."

  attr :checked, :boolean, doc: "Checkbox checked state (checkbox type only)."
  attr :prompt, :string, default: nil, doc: "Empty first <option> label (select type only)."
  attr :options, :list, doc: "Select options for options_for_select/2 (select type only)."
  attr :multiple, :boolean, default: false, doc: "Allow multi-select; appends [] to the name."

  attr :rest, :global,
    doc: "Passthrough HTML attrs on the control element.",
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label class="flex items-center gap-4 text-sm leading-6 text-zinc-600">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="rounded border-zinc-300 text-zinc-900 focus:ring-0"
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class="mt-2 block w-full rounded-md border border-gray-300 bg-white shadow-sm focus:border-zinc-400 focus:ring-0 sm:text-sm"
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6 min-h-[6rem]",
          @errors == [] && "border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "mt-2 block w-full rounded-lg text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6",
          @errors == [] && "border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil, doc: "id of the labelled control (label for=)."
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="block text-sm font-semibold leading-6 text-zinc-800">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-3 flex gap-3 text-sm leading-6 text-rose-600">
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil, doc: "Extra classes on the <header>."

  slot :inner_block, required: true
  slot :subtitle, doc: "Secondary line under the title."
  slot :actions, doc: "Right-aligned actions (buttons/links)."

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-zinc-800">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-zinc-600">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true, doc: "tbody id (required for LiveStream phx-update)."
  attr :rows, :list, required: true, doc: "Row enumerable or LiveStream."
  attr :row_id, :any, default: nil, doc: "fn(row) → DOM id; default for streams is the stream id."
  attr :row_click, :any, default: nil, doc: "fn(row) → JS/phx-click for each data cell."

  attr :row_item, :any,
    doc: "fn(row) → value passed into :col and :action slots.",
    default: &Function.identity/1

  slot :col, required: true do
    attr :label, :string, doc: "Column header text."
  end

  slot :action, doc: "Trailing per-row actions column."

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-y-auto px-4 sm:overflow-visible sm:px-0">
      <table class="w-[40rem] mt-11 sm:w-full">
        <thead class="text-sm text-left leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @col} class="p-0 pb-4 pr-6 font-normal">{col[:label]}</th>
            <th :if={@action != []} class="relative p-0 pb-4">
              <span class="sr-only">{"Actions"}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="relative divide-y divide-zinc-100 border-t border-zinc-200 text-sm leading-6 text-zinc-700"
        >
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group hover:bg-zinc-50">
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={["relative p-0", @row_click && "hover:cursor-pointer"]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-zinc-50 sm:rounded-l-xl" />
                <span class={["relative", i == 0 && "font-semibold text-zinc-900"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
            <td :if={@action != []} class="relative w-14 p-0">
              <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
                <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-zinc-50 sm:rounded-r-xl" />
                <span
                  :for={action <- @action}
                  class="relative ml-4 font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
                >
                  {render_slot(action, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true, doc: "dt label for this row."
  end

  def list(assigns) do
    ~H"""
    <div class="mt-14">
      <dl class="-my-4 divide-y divide-zinc-100">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-zinc-500">{item.title}</dt>
          <dd class="text-zinc-700">{render_slot(item)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back navigate={~p"/posts"}>Back to posts</.back>
  """
  attr :navigate, :any, required: true, doc: "LiveView navigate path for the back link."
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link
        navigate={@navigate}
        class="text-sm font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
      >
        <.icon name="hero-arrow-left-solid" class="h-3 w-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true, doc: "Heroicon class (hero-*-solid|mini|outline)."
  attr :class, :string, default: nil, doc: "Size/colour utilities on the icon span."

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  @doc """
  Renders a changeset error message, interpolating its `%{binding}` opts.

  Ecto emits errors as `{msg, opts}` where `msg` carries `%{count}`-style
  bindings. There is no i18n layer here — the message is used verbatim with
  its bindings substituted.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
