defmodule OmashikiWeb.CoreComponents do
  @moduledoc """
  Core UI building blocks: flash notices, buttons, text inputs, alert
  banners, icons, the flash show/hide JS commands, and changeset error
  translation. Styled with Tailwind CSS against the Omashiki tokens.

  Icons are provided by [heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

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
        "fixed top-4 right-4 left-4 sm:left-auto sm:w-96 z-50 p-4 border font-body text-sm bg-surface-container-high text-on-surface",
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
