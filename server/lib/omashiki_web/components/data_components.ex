defmodule OmashikiWeb.DataComponents do
  @moduledoc """
  Reusable data primitives (waffle, gauge, spark, timeline, …).

  Colours come only from design tokens (`var(--…)` or Tailwind classes mapped
  to those tokens). Inline SVG for chart-like shapes — no chart library.

  `nil` is not zero: measured-absent values render as an em dash (`—`).

  ## Tone vocabulary

  * **Paint** (`@tone_values`) — charts, progress, status_dot: includes
    `:cancelled`, `:primary`, `:muted`.
  * **KPI** (`stat/1`) — subset
    `:neutral | :success | :failed | :warning | :info`.

  `tone_class/1`, `status_tone/1`, and `tone_fill/1` live here.

  SVG stroke convention: `stroke="currentColor"` + a Tailwind `text-*`
  class on the `<svg>` (see `spark/1`).
  """

  use Phoenix.Component

  @em_dash "—"

  # Finite tone vocabulary shared by paint helpers and `attr … values:`.
  @tone_values [:success, :failed, :warning, :info, :cancelled, :neutral, :primary, :muted]

  # ---------------------------------------------------------------------------
  # Shared helpers (public)
  # ---------------------------------------------------------------------------

  @doc "Format a measured value; `nil` becomes an em dash, never `\"0\"`."
  def display_value(nil), do: @em_dash
  def display_value(value) when is_binary(value), do: value
  def display_value(value), do: to_string(value)

  @doc """
  Translate a `:tone` atom to a Tailwind text class.

  Covers the full paint vocabulary (`@tone_values`). KPI surfaces
  (`stat/1`) only pass the five-tone subset.
  """
  def tone_class(:success), do: "text-status-success"
  def tone_class(:failed), do: "text-status-failed"
  def tone_class(:warning), do: "text-status-awaiting"
  def tone_class(:info), do: "text-status-running"
  def tone_class(:cancelled), do: "text-status-cancelled"
  def tone_class(:neutral), do: "text-on-surface"
  def tone_class(:primary), do: "text-primary-container"
  def tone_class(:muted), do: "text-on-surface-variant"
  def tone_class(_), do: "text-on-surface"

  @doc "Background class for dots / chips — mirrors `tone_class/1`."
  def tone_bg_class(:success), do: "bg-status-success"
  def tone_bg_class(:failed), do: "bg-status-failed"
  def tone_bg_class(:warning), do: "bg-status-awaiting"
  def tone_bg_class(:info), do: "bg-status-running"
  def tone_bg_class(:cancelled), do: "bg-status-cancelled"
  def tone_bg_class(:neutral), do: "bg-on-surface"
  def tone_bg_class(:primary), do: "bg-primary-container"
  def tone_bg_class(:muted), do: "bg-outline-variant"
  def tone_bg_class(_), do: "bg-on-surface"

  @doc """
  CSS `var(--…)` fill for inline SVG (multi-colour scenes where
  `currentColor` is not enough). Prefer `currentColor` + `tone_class/1` on
  the `<svg>` when the stroke is uniform — see `spark/1`.
  """
  def tone_fill(:success), do: "var(--app-color-status-success)"
  def tone_fill(:failed), do: "var(--app-color-status-failed)"
  def tone_fill(:warning), do: "var(--app-color-status-awaiting)"
  def tone_fill(:info), do: "var(--app-color-status-running)"
  def tone_fill(:cancelled), do: "var(--app-color-status-cancelled)"
  def tone_fill(:neutral), do: "var(--md-sys-color-on-surface)"
  def tone_fill(:muted), do: "var(--md-sys-color-outline-variant)"
  def tone_fill(:primary), do: "var(--md-sys-color-primary-container)"
  def tone_fill(_), do: "var(--md-sys-color-on-surface)"

  @doc """
  Map a status label (raw or humanised) to a tone atom.

  Covers task/run labels plus circuit-breaker (`closed`/`open`/`half_open`)
  and engine (`retired`) / fallback (`standby`) vocabulary used by
  `<.status_dot>`.
  """
  def status_tone(label) do
    case label |> to_string() |> String.downcase() do
      s when s in ~w(success completed succeeded ok done closed) ->
        :success

      s when s in ~w(failed failure error open) ->
        :failed

      s when s in ~w(cancelled canceled aborted retired) ->
        :cancelled

      s
      when s in ~w(awaiting awaiting_commit awaiting_input pending waiting blocked dirty half_open) ->
        :warning

      s when s in ~w(running active in_progress standby) ->
        :info

      s when s in ~w(idle ready) ->
        :neutral

      _ ->
        :cancelled
    end
  end

  @doc """
  Token fill for a status label — SVG/HTML fill via `tone_fill/1`.
  """
  def status_color(label), do: label |> status_tone() |> tone_fill()

  @doc """
  Fetch chrome for remote data — loading or error, never a fake measurement.

  Use instead of rendering charts/tables while `state != :ok`. Loading is not
  empty and not zero: no waffle cells, no `0`, no em dash (those mean
  "measured absent"). Error shows `error` or a default failure line.
  """
  attr :state, :atom,
    doc: ":loading | :error (only — :ok is the caller's content branch).",
    required: true,
    values: [:loading, :error]

  attr :error, :string, doc: "Failure copy when state=:error.", default: nil
  attr :loading_label, :string, doc: "In-flight copy when state=:loading.", default: "Loading…"
  attr :class, :string, doc: "Extra classes on the chrome node.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the chrome node."

  def fetch_state(assigns) do
    ~H"""
    <p
      :if={@state == :loading}
      class={["font-mono text-xs text-on-surface-variant", @class]}
      aria-busy="true"
      aria-live="polite"
      {@rest}
    >
      {@loading_label}
    </p>
    <p
      :if={@state == :error}
      class={["font-mono text-xs text-status-failed", @class]}
      role="alert"
      {@rest}
    >
      {@error || "Failed to load."}
    </p>
    """
  end

  defp resolve_tone(assigns) do
    cond do
      is_atom(assigns[:tone]) and not is_nil(assigns[:tone]) -> assigns.tone
      not is_nil(assigns[:status]) -> status_tone(assigns.status)
      true -> :neutral
    end
  end

  # ---------------------------------------------------------------------------
  # waffle
  # ---------------------------------------------------------------------------

  @doc """
  Capacity waffle — grid of unit cells.

  * `total` — cell count
  * `used` — filled cells (claimed)
  * `reachable` — soft ceiling; cells beyond this are unreachable (dimmed)
  * `cols` — columns in the grid (default 10)
  """
  attr :total, :integer, doc: "Cell count in the grid (required).", required: true
  attr :used, :integer, doc: "Filled cells; clamped to 0..total.", default: 0

  attr :reachable, :integer,
    doc: "Soft ceiling; beyond = unreachable. Default total.",
    default: nil

  attr :cols, :integer, doc: "Grid column count (default 10).", default: 10
  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def waffle(assigns) do
    total = max(assigns.total, 0)
    used = assigns.used |> Kernel.||(0) |> max(0) |> min(total)
    reachable = assigns.reachable || total
    cols = max(assigns.cols, 1)
    rows = if total == 0, do: 0, else: ceil(total / cols)
    cell = 10
    gap = 2
    width = cols * cell + max(cols - 1, 0) * gap
    height = max(rows, 1) * cell + max(rows - 1, 0) * gap

    cells =
      for i <- 0..(max(total, 1) - 1), total > 0 do
        {i, waffle_state(i, used, reachable, total)}
      end

    assigns =
      assigns
      |> assign(:cells, cells)
      |> assign(:cols, cols)
      |> assign(:cell, cell)
      |> assign(:gap, gap)
      |> assign(:width, width)
      |> assign(:height, height)
      |> assign(:empty?, total == 0)
      |> assign(:used, used)
      |> assign(:total, total)
      |> assign(:aria_label, waffle_aria_label(used, total, reachable))

    ~H"""
    <div class={["inline-block", @class]} {@rest}>
      <svg
        :if={!@empty?}
        viewBox={"0 0 #{@width} #{@height}"}
        width={@width}
        height={@height}
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax={@total}
        aria-valuenow={@used}
        aria-label={@aria_label}
      >
        <rect
          :for={{i, state} <- @cells}
          x={rem(i, @cols) * (@cell + @gap)}
          y={div(i, @cols) * (@cell + @gap)}
          width={@cell}
          height={@cell}
          fill={waffle_fill(state)}
        />
      </svg>
      <p :if={@empty?} class="font-mono text-xs text-on-surface-variant">{display_value(nil)}</p>
    </div>
    """
  end

  defp waffle_aria_label(used, total, reachable) when reachable < total do
    "#{used} of #{total} used, #{reachable} reachable"
  end

  defp waffle_aria_label(used, total, _reachable), do: "#{used} of #{total} used"

  defp waffle_state(i, used, reachable, _total) do
    cond do
      i < used -> :used
      i < reachable -> :free
      true -> :unreachable
    end
  end

  defp waffle_fill(:used), do: "var(--md-sys-color-primary-container)"
  defp waffle_fill(:free), do: "var(--md-sys-color-surface-container-high)"
  defp waffle_fill(:unreachable), do: "var(--md-sys-color-outline-variant)"

  # ---------------------------------------------------------------------------
  # gauge
  # ---------------------------------------------------------------------------

  @doc """
  Horizontal capacity gauge with optional hard `cap` marker.
  """
  attr :label, :string, doc: "Caption above the track.", required: true
  attr :used, :any, doc: "Consumed amount; nil → em dash / empty fill.", default: nil
  attr :total, :any, doc: "Capacity denominator; nil → empty track.", default: nil
  attr :unit, :string, doc: "Optional unit suffix (slots, GB, …).", default: nil
  attr :cap, :any, doc: "Optional hard-cap marker on the total scale.", default: nil
  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def gauge(assigns) do
    used_n = numeric(assigns.used)
    total_n = numeric(assigns.total)
    cap_n = numeric(assigns.cap)

    ratio =
      cond do
        is_nil(used_n) or is_nil(total_n) or total_n <= 0 -> nil
        true -> min(used_n / total_n, 1.0)
      end

    cap_ratio =
      cond do
        is_nil(cap_n) or is_nil(total_n) or total_n <= 0 -> nil
        true -> min(cap_n / total_n, 1.0)
      end

    assigns =
      assigns
      |> assign(:ratio, ratio)
      |> assign(:cap_ratio, cap_ratio)
      |> assign(:used_label, display_value(assigns.used))
      |> assign(:total_label, display_value(assigns.total))
      |> assign(:aria_now, aria_number(used_n))
      |> assign(:aria_max, if(is_number(total_n) and total_n > 0, do: aria_number(total_n)))
      |> assign(
        :aria_label,
        gauge_aria_label(assigns.label, assigns.used, assigns.total, assigns.unit)
      )

    ~H"""
    <div
      class={["flex flex-col gap-2 min-w-[10rem]", @class]}
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax={@aria_max}
      aria-valuenow={@aria_now}
      aria-label={@aria_label}
      {@rest}
    >
      <div class="flex items-baseline justify-between gap-3">
        <span class="type-caption text-on-surface-variant">{@label}</span>
        <span class="font-mono text-xs text-on-surface tabular-nums">
          {@used_label}<span class="text-on-surface-variant"> / </span>{@total_label}{if @unit,
            do: " #{@unit}",
            else: ""}
        </span>
      </div>
      <svg viewBox="0 0 100 8" class="w-full h-2" aria-hidden="true">
        <rect
          x="0"
          y="0"
          width="100"
          height="8"
          fill="var(--md-sys-color-surface-container-high)"
        />
        <rect
          :if={@ratio}
          x="0"
          y="0"
          width={Float.round(@ratio * 100, 2)}
          height="8"
          fill="var(--md-sys-color-primary-container)"
        />
        <line
          :if={@cap_ratio}
          x1={Float.round(@cap_ratio * 100, 2)}
          x2={Float.round(@cap_ratio * 100, 2)}
          y1="0"
          y2="8"
          stroke="var(--app-color-status-awaiting)"
          stroke-width="1.5"
        />
      </svg>
    </div>
    """
  end

  defp gauge_aria_label(label, used, total, unit) do
    unit_suffix = if unit in [nil, ""], do: "", else: " #{unit}"
    "#{label}: #{display_value(used)} of #{display_value(total)}#{unit_suffix}"
  end

  defp aria_number(nil), do: nil
  defp aria_number(n) when is_integer(n), do: n
  defp aria_number(n) when is_float(n) and n == trunc(n), do: trunc(n)
  defp aria_number(n) when is_float(n), do: n

  # ---------------------------------------------------------------------------
  # spark
  # ---------------------------------------------------------------------------

  @doc """
  Inline sparkline. `values` is a list of numbers; `nil` entries are gaps.

  Stroke: `currentColor` on a `<polyline>` with the tone as a Tailwind
  `text-*` class on the `<svg>` (`preserveAspectRatio="none"`,
  `vector-effect="non-scaling-stroke"`).

  * `rail` — viewBox height and CSS rail class together (default `14` /
    `h-3.5`; pass `12` / `h-3` for run-history sparklines).
  * `scale_max` — when set (e.g. `100.0` for cpu%), normalize against a
    fixed ceiling instead of the sample min/max (matches workspace
    telemetry rails).
  * `class` — replaces the default `inline-block w-28` wrapper when given
    (pass `flex-1` for full-width rails).
  * `stroke_class` — optional Tailwind class on the `<svg>` overriding `tone`.
  """
  attr :values, :list, doc: "Numeric samples; nil entries are gaps, not zeros.", default: []

  attr :variant, :atom,
    doc: ":line polyline or :area filled under the line.",
    default: :line,
    values: [:line, :area]

  attr :tone, :atom,
    doc: "Stroke/fill token (:primary, :info, …).",
    default: :primary,
    values: @tone_values

  attr :rail, :integer, doc: "ViewBox height; 14→h-3.5, 12→h-3.", default: 14
  attr :scale_max, :any, doc: "Fixed y ceiling (e.g. 100.0); nil → sample min/max.", default: nil

  attr :stroke_class, :string,
    doc: "Optional Tailwind class on <svg> overriding tone.",
    default: nil

  attr :label, :string,
    doc: "Accessible name when the spark is not decorative beside a visible figure.",
    default: nil

  attr :class, :string, doc: "Wrapper class; nil keeps inline-block w-28.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def spark(assigns) do
    rail = spark_rail(assigns.rail)
    points = spark_points(assigns.values || [], assigns.scale_max, rail)
    poly = spark_polyline(points)
    area = spark_area_path(points, rail)
    empty? = points == []

    assigns =
      assigns
      |> assign(:rail, rail)
      |> assign(:poly, poly)
      |> assign(:area, area)
      |> assign(:empty?, empty?)
      |> assign(:svg_tone, assigns.stroke_class || tone_class(assigns.tone))
      |> assign(:fill, tone_fill(assigns.tone))
      |> assign(:wrap_class, assigns.class || "inline-block w-28")
      |> assign(:svg_h_class, spark_rail_class(rail))
      |> assign(:decorative?, assigns.label in [nil, ""])

    ~H"""
    <div class={@wrap_class} {@rest}>
      <svg
        :if={!@empty?}
        viewBox={"0 0 100 #{@rail}"}
        preserveAspectRatio="none"
        class={["w-full", @svg_h_class, @svg_tone]}
        aria-hidden={if @decorative?, do: "true"}
        role={unless @decorative?, do: "img"}
        aria-label={unless @decorative?, do: @label}
      >
        <path
          :if={@variant == :area and @area}
          d={@area}
          fill={@fill}
          fill-opacity="0.25"
          stroke="none"
        />
        <polyline
          points={@poly}
          fill="none"
          stroke="currentColor"
          stroke-width="1"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <span :if={@empty?} class="font-mono text-xs text-on-surface-variant">
        {display_value(nil)}
      </span>
    </div>
    """
  end

  defp spark_rail(n) when is_integer(n) and n > 0, do: n
  defp spark_rail(_), do: 14

  # Rail 14 → h-3.5 (telemetry); rail 12 → h-3 (run history).
  defp spark_rail_class(12), do: "h-3"
  defp spark_rail_class(_), do: "h-3.5"

  defp spark_points(values, scale_max, rail) do
    nums =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {v, i} when is_number(v) -> [{i, v * 1.0}]
        _ -> []
      end)

    # 1px vertical pad on the 14-rail (telemetry); full height on 12-rail
    # (run history) — matches the two former workspace SVG geometries.
    pad = if rail >= 14, do: 1.0, else: 0.0
    usable = rail - 2 * pad
    mid = rail / 2.0

    case nums do
      [] ->
        []

      [{_i, _y}] ->
        [{0.0, mid}, {100.0, mid}]

      list ->
        ys = Enum.map(list, &elem(&1, 1))

        {min_y, max_y} =
          case numeric(scale_max) do
            nil -> {Enum.min(ys), Enum.max(ys)}
            ceiling -> {0.0, max(ceiling, 1.0e-9)}
          end

        span = max(max_y - min_y, 1.0e-9)
        max_i = max(length(values) - 1, 1)

        Enum.map(list, fn {i, y} ->
          x = i / max_i * 100
          yy = rail - pad - (y - min_y) / span * usable
          {x, yy}
        end)
    end
  end

  defp spark_polyline([]), do: ""

  defp spark_polyline(points) do
    Enum.map_join(points, " ", fn {x, y} -> "#{svg_coord(x)},#{svg_coord(y)}" end)
  end

  defp spark_area_path([], _rail), do: nil

  defp spark_area_path(points, rail) do
    [{x0, _} | _] = points
    {xn, _} = List.last(points)

    line =
      points
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {{x, y}, i} ->
        cmd = if i == 0, do: "M", else: "L"
        "#{cmd} #{svg_coord(x)} #{svg_coord(y)}"
      end)

    line <> " L #{svg_coord(xn)} #{rail} L #{svg_coord(x0)} #{rail} Z"
  end

  @doc """
  Format a number as an SVG path/attribute coordinate (two decimal places).

  Not a general-purpose number formatter — do not use for currency, tokens,
  or displayed stats. Callers that need another precision must format
  explicitly at the call site.
  """
  def svg_coord(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  def svg_coord(n), do: to_string(n)

  # ---------------------------------------------------------------------------
  # stat
  # ---------------------------------------------------------------------------

  @doc """
  Statistic / KPI **content** (label + value) — no bordered card.

  * `label` — required
  * `value` — any; `nil` → `—`
  * `tone` — KPI subset `:neutral | :success | :failed | :warning | :info`
  * `hint` — optional secondary line
  * `state` / `error` — fetch chrome; loading/error never paint a figure

  ## Container queries

  This root intentionally has **no** `cq` / `container-type`. A flex or
  grid item with `container-type: inline-size` is sized as if it had no
  content (intrinsic inline size → 0), so labels collapse
  (`TOTAL`/`USD`/`TOKENS` colliding, `—/—` wrapping). Put `cq` on a
  **layout-sized** ancestor instead — block width, grid track, or a flex
  item with a definite basis / `flex-1` — never on a content-sized flex
  child. `cq-md-text-3xl` on the figure queries that ancestor (same
  pattern as `kv_row/1`: containment context ≠ the node that needs
  content-based sizing).
  """
  attr :label, :string, doc: "Uppercase caption above the value (required).", required: true
  attr :value, :any, doc: "Figure; nil → em dash, never coerced to 0.", default: nil
  attr :hint, :string, doc: "Optional secondary line under the value.", default: nil

  attr :tone, :atom,
    doc: ":neutral|:success|:failed|:warning|:info (kpi vocab).",
    default: :neutral,
    values: [:neutral, :success, :failed, :warning, :info]

  attr :state, :atom,
    doc: ":ok | :loading | :error — loading/error never paint a figure.",
    default: :ok,
    values: [:ok, :loading, :error]

  attr :error, :string, doc: "Failure copy when state=:error.", default: nil
  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def stat(assigns) do
    assigns = assign(assigns, :display, display_value(assigns.value))

    ~H"""
    <div class={["flex flex-col", @class]} {@rest}>
      <div class="font-label text-label-md tracking-[0.3em] uppercase text-on-surface-variant">
        {@label}
      </div>
      <.fetch_state :if={@state != :ok} state={@state} error={@error} class="mt-3 text-2xl" />
      <div
        :if={@state == :ok}
        class={[
          "font-mono text-2xl cq-md-text-3xl mt-3 tabular-nums leading-none",
          tone_class(@tone)
        ]}
      >
        {@display}
      </div>
      <div :if={@state == :ok and @hint} class="font-body text-xs text-on-surface-variant mt-2">
        {@hint}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # progress
  # ---------------------------------------------------------------------------

  @doc """
  Linear progress. `value` is 0..1 (or nil → empty track, no fill).
  """
  attr :label, :string,
    doc: "Accessible name for the progressbar (required — what is filling?).",
    required: true

  attr :value, :any, doc: "Fill ratio 0..1; nil → empty track.", default: nil

  attr :tone, :atom,
    doc: "Fill colour token (:primary, :success, …).",
    default: :primary,
    values: @tone_values

  attr :size, :atom, doc: "Track height :sm|:md|:lg.", default: :md, values: [:sm, :md, :lg]
  attr :class, :string, doc: "Extra classes on the track.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the track."

  def progress(assigns) do
    ratio =
      case numeric(assigns.value) do
        nil -> nil
        n -> n |> max(0.0) |> min(1.0)
      end

    height =
      case assigns.size do
        :sm -> "h-1"
        :lg -> "h-3"
        _ -> "h-2"
      end

    assigns =
      assigns
      |> assign(:ratio, ratio)
      |> assign(:height, height)
      |> assign(:fill, tone_fill(assigns.tone))

    ~H"""
    <div
      class={["w-full bg-surface-container-high overflow-hidden", @height, @class]}
      role="progressbar"
      aria-label={@label}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={if @ratio, do: round(@ratio * 100), else: nil}
      {@rest}
    >
      <div
        :if={@ratio}
        class="h-full transition-[width]"
        style={"width: #{Float.round(@ratio * 100, 2)}%; background: #{@fill}"}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # donut
  # ---------------------------------------------------------------------------

  @doc """
  Ring / donut. `value` and optional `min` (threshold) are 0..1 or absolute
  with the same unit; when either is nil the ring is empty and the centre
  shows `—`.
  """
  attr :value, :any, doc: "Ring fill 0..1; nil → empty ring + centre —.", default: nil
  attr :min, :any, doc: "Optional threshold tick (same 0..1 scale).", default: nil

  attr :label, :string,
    doc: "Caption under the ring; included in the accessible name.",
    default: nil

  attr :tone, :atom,
    doc: "Ring stroke colour token.",
    default: :primary,
    values: @tone_values

  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def donut(assigns) do
    value_n = numeric(assigns.value)
    min_n = numeric(assigns.min)
    r = 15.5
    c = 2 * :math.pi() * r

    {dash, offset} =
      case value_n do
        nil ->
          {"0", "0"}

        v ->
          clamped = v |> max(0.0) |> min(1.0)
          {svg_coord(clamped * c), svg_coord(c * 0.25)}
      end

    min_dash =
      case min_n do
        nil -> nil
        v -> svg_coord(max(v, 0.0) |> min(1.0) |> Kernel.*(c))
      end

    pct = if value_n, do: round(value_n * 100)

    assigns =
      assigns
      |> assign(:r, r)
      |> assign(:c, c)
      |> assign(:dash, dash)
      |> assign(:offset, offset)
      |> assign(:min_dash, min_dash)
      |> assign(:centre, display_value(if(pct, do: "#{pct}%", else: nil)))
      |> assign(:fill, tone_fill(assigns.tone))
      |> assign(:aria_now, pct)
      |> assign(:aria_label, donut_aria_label(assigns.label, pct))

    ~H"""
    <div class={["inline-flex flex-col items-center gap-2", @class]} {@rest}>
      <svg
        viewBox="0 0 40 40"
        class="w-16 h-16"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={@aria_now}
        aria-label={@aria_label}
      >
        <circle
          cx="20"
          cy="20"
          r={@r}
          fill="none"
          stroke="var(--md-sys-color-surface-container-high)"
          stroke-width="4"
        />
        <circle
          :if={@value != nil}
          cx="20"
          cy="20"
          r={@r}
          fill="none"
          stroke={@fill}
          stroke-width="4"
          stroke-dasharray={"#{@dash} #{svg_coord(@c)}"}
          stroke-dashoffset={@offset}
          stroke-linecap="butt"
          transform="rotate(-90 20 20)"
        />
        <circle
          :if={@min_dash}
          cx="20"
          cy="20"
          r={@r}
          fill="none"
          stroke="var(--app-color-status-awaiting)"
          stroke-width="1"
          stroke-dasharray={"1 #{svg_coord(@c)}"}
          stroke-dashoffset={svg_coord(@c * 0.25 - (numeric(@min) || 0) * @c)}
          transform="rotate(-90 20 20)"
        />
        <text
          x="20"
          y="21.5"
          text-anchor="middle"
          class="font-mono"
          fill="var(--md-sys-color-on-surface)"
          font-size="7"
          aria-hidden="true"
        >
          {@centre}
        </text>
      </svg>
      <span :if={@label} class="type-caption text-on-surface-variant">{@label}</span>
    </div>
    """
  end

  defp donut_aria_label(label, nil) when label in [nil, ""], do: "unmeasured"
  defp donut_aria_label(label, nil), do: "#{label}: unmeasured"
  defp donut_aria_label(label, pct) when label in [nil, ""], do: "#{pct}%"
  defp donut_aria_label(label, pct), do: "#{label}: #{pct}%"

  # ---------------------------------------------------------------------------
  # matrix
  # ---------------------------------------------------------------------------

  @doc """
  Grid matrix. `cells` is a list of `{row, col, tone}` or maps with
  `:row`, `:col`, `:tone` keys. Empty `rows`/`cols` shows a dash.
  """
  attr :rows, :list, doc: "Row labels; empty axes → em dash.", default: []
  attr :cols, :list, doc: "Column labels.", default: []
  attr :cells, :list, doc: "{row,col,tone} tuples or %{row,col,tone} (0-based).", default: []
  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def matrix(assigns) do
    row_count = length(assigns.rows || [])
    col_count = length(assigns.cols || [])
    lookup = matrix_lookup(assigns.cells || [])
    empty? = row_count == 0 or col_count == 0

    assigns =
      assigns
      |> assign(:row_count, row_count)
      |> assign(:col_count, col_count)
      |> assign(:lookup, lookup)
      |> assign(:empty?, empty?)

    ~H"""
    <div class={["overflow-x-auto", @class]} {@rest}>
      <p :if={@empty?} class="font-mono text-xs text-on-surface-variant">{display_value(nil)}</p>
      <table :if={!@empty?} class="border-collapse text-xs">
        <thead>
          <tr>
            <th class="p-1"></th>
            <th
              :for={col <- @cols}
              scope="col"
              class="type-chrome-dense text-on-surface-variant px-2 py-1 font-normal text-left"
            >
              {col}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{row, ri} <- Enum.with_index(@rows)}>
            <th
              scope="row"
              class="type-chrome-dense text-on-surface-variant px-2 py-1 font-normal text-left whitespace-nowrap"
            >
              {row}
            </th>
            <td :for={{_col, ci} <- Enum.with_index(@cols)} class="p-1">
              <span
                class="block w-4 h-4 border border-outline-variant"
                style={"background: #{tone_fill(Map.get(@lookup, {ri, ci}, :muted))}"}
                title={"#{row} × #{Enum.at(@cols, ci)}"}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp matrix_lookup(cells) do
    Enum.reduce(cells, %{}, fn
      {r, c, tone}, acc when is_integer(r) and is_integer(c) ->
        Map.put(acc, {r, c}, tone)

      %{row: r, col: c, tone: tone}, acc ->
        Map.put(acc, {r, c}, tone)

      %{row: r, col: c}, acc ->
        Map.put(acc, {r, c}, :primary)

      _, acc ->
        acc
    end)
  end

  # ---------------------------------------------------------------------------
  # timeline
  # ---------------------------------------------------------------------------

  @doc """
  Multi-lane timeline. `lanes` is a list of `%{label: _, segments: [%{from:, to:, tone:}]}`.
  `from`/`to` are domain bounds (numbers or DateTime-compatible); nil domain → empty.

  Real event logs: many lanes (one per activity), short/instant segments, long
  labels like `container.provisioned`. Label column is wider; lane labels are
  truncated with SVG `<title>` for the full name; the SVG sits in a scroll
  pane so dense logs do not blow the panel.
  """
  attr :lanes, :list, doc: "%{label, segments: [%{from,to,tone,label?}]}.", default: []
  attr :from, :any, doc: "Domain start (number/DateTime); nil → empty.", default: nil

  attr :to, :any,
    doc: "Domain end; nil → empty. Equal to from is nudged (+1) so instant events paint.",
    default: nil

  attr :label, :string,
    doc: "Optional accessible name override; default summarises lanes and domain.",
    default: nil

  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def timeline(assigns) do
    domain_from = timeline_num(assigns.from)
    domain_to = timeline_num(assigns.to)
    lanes = assigns.lanes || []

    # Instant domain (all events in one second) — nudge so segments paint.
    {domain_from, domain_to} =
      cond do
        is_nil(domain_from) or is_nil(domain_to) -> {domain_from, domain_to}
        domain_to > domain_from -> {domain_from, domain_to}
        true -> {domain_from, domain_from + 1}
      end

    empty? =
      is_nil(domain_from) or is_nil(domain_to) or domain_to <= domain_from or lanes == []

    lane_h = 14
    gap = 6
    label_w = 108
    track_w = 220
    height = max(length(lanes) * (lane_h + gap) - gap, lane_h)

    assigns =
      assigns
      |> assign(:empty?, empty?)
      |> assign(:domain_from, domain_from)
      |> assign(:domain_to, domain_to)
      |> assign(:lane_h, lane_h)
      |> assign(:gap, gap)
      |> assign(:label_w, label_w)
      |> assign(:track_w, track_w)
      |> assign(:height, height)
      |> assign(:span, if(empty?, do: 1.0, else: domain_to - domain_from))
      |> assign(
        :aria_label,
        assigns.label || timeline_aria_label(lanes, domain_from, domain_to)
      )

    ~H"""
    <div class={["w-full", @class]} {@rest}>
      <p :if={@empty?} class="font-mono text-xs text-on-surface-variant">{display_value(nil)}</p>
      <div :if={!@empty?} class="overflow-auto max-h-80">
        <svg
          viewBox={"0 0 #{@label_w + @track_w} #{@height}"}
          width={@label_w + @track_w}
          height={@height}
          class="max-w-none block"
          role="img"
          aria-label={@aria_label}
        >
          <g :for={{lane, li} <- Enum.with_index(@lanes || [])}>
            <text
              x="0"
              y={li * (@lane_h + @gap) + @lane_h * 0.75}
              fill="var(--md-sys-color-on-surface-variant)"
              font-size="8"
              font-family="var(--font-mono)"
            >
              <title>{Map.get(lane, :label) || Map.get(lane, "label") || ""}</title>
              {truncate_timeline_label(Map.get(lane, :label) || Map.get(lane, "label") || "")}
            </text>
            <rect
              x={@label_w}
              y={li * (@lane_h + @gap)}
              width={@track_w}
              height={@lane_h}
              fill="var(--md-sys-color-surface-container-high)"
            />
            <g :for={seg <- Map.get(lane, :segments) || Map.get(lane, "segments") || []}>
              <rect
                x={@label_w + timeline_x(seg, @domain_from, @span, @track_w)}
                y={li * (@lane_h + @gap) + 2}
                width={max(timeline_w(seg, @span, @track_w), 2)}
                height={@lane_h - 4}
                fill={tone_fill(Map.get(seg, :tone) || Map.get(seg, "tone") || :primary)}
              >
                <title>{segment_title(seg)}</title>
              </rect>
              <text
                :if={segment_label(seg)}
                x={@label_w + timeline_x(seg, @domain_from, @span, @track_w) + 3}
                y={li * (@lane_h + @gap) + @lane_h * 0.72}
                fill="var(--md-sys-color-on-surface)"
                font-size="7"
                font-family="var(--font-mono)"
              >
                {segment_label(seg)}
              </text>
            </g>
          </g>
        </svg>
      </div>
    </div>
    """
  end

  defp timeline_num(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp timeline_num(%NaiveDateTime{} = dt),
    do: NaiveDateTime.diff(dt, ~N[1970-01-01 00:00:00], :second)

  defp timeline_num(n) when is_number(n), do: n
  defp timeline_num(_), do: nil

  defp timeline_aria_label(lanes, from, to) do
    names =
      lanes
      |> Enum.map(fn lane -> Map.get(lane, :label) || Map.get(lane, "label") end)
      |> Enum.reject(&(&1 in [nil, ""]))

    lane_part =
      case names do
        [] -> "#{length(lanes)} lanes"
        list -> Enum.join(list, ", ")
      end

    "#{lane_part}, #{display_value(from)} to #{display_value(to)}"
  end

  defp truncate_timeline_label(label) when is_binary(label) do
    if String.length(label) <= 16, do: label, else: String.slice(label, 0, 15) <> "…"
  end

  defp truncate_timeline_label(other), do: truncate_timeline_label(to_string(other))

  defp segment_label(seg) when is_map(seg) do
    case Map.get(seg, :label) || Map.get(seg, "label") do
      label when is_binary(label) and label != "" -> label
      _ -> nil
    end
  end

  defp segment_label(_), do: nil

  defp segment_title(seg) do
    case segment_label(seg) do
      nil -> ""
      label -> label
    end
  end

  defp timeline_x(seg, domain_from, span, track_w) do
    from = timeline_num(Map.get(seg, :from) || Map.get(seg, "from")) || domain_from
    ((from - domain_from) / span * track_w) |> max(0) |> min(track_w)
  end

  defp timeline_w(seg, span, track_w) do
    from = timeline_num(Map.get(seg, :from) || Map.get(seg, "from")) || 0
    to = timeline_num(Map.get(seg, :to) || Map.get(seg, "to")) || from
    ((to - from) / span * track_w) |> max(0) |> min(track_w)
  end

  # ---------------------------------------------------------------------------
  # bar_group
  # ---------------------------------------------------------------------------

  @doc """
  Grouped vertical bars.

  `series` accepts either:

  * a list of series — `[[y0, y1, …], [y0, y1, …]]` (one inner list per series)
  * a flat list of numbers/nils — `[y0, y1, …]` (single series; wrapped internally)

  `nil` values are skipped (not drawn as zero-height bars). `labels` names
  each category on the x-axis (index-aligned with each series' values).
  """
  attr :series, :list, doc: "Nested [[y…]] or flat [y|nil]; nil skips bar.", default: []
  attr :labels, :list, doc: "X-axis category labels, index-aligned.", default: []

  attr :tones, :list,
    doc: "Tone per series (default [:primary,:info,:warning]).",
    default: [:primary, :info, :warning]

  attr :label, :string,
    doc: "Optional accessible name override; default joins category labels.",
    default: nil

  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."

  def bar_group(assigns) do
    labels = assigns.labels || []
    series = normalize_bar_series(assigns.series || [])
    tones = assigns.tones || [:primary, :info, :warning]
    empty? = labels == [] or series == [] or Enum.all?(series, &(&1 == []))

    flat =
      series
      |> List.flatten()
      |> Enum.filter(&is_number/1)

    max_v = if flat == [], do: 1.0, else: max(Enum.max(flat), 1.0e-9)
    n = max(length(labels), 1)
    group_w = 80 / n
    bar_w = group_w / max(length(series), 1) * 0.8

    bars =
      for {label, li} <- Enum.with_index(labels),
          {serie, si} <- Enum.with_index(series),
          val = Enum.at(serie, li),
          val != nil do
        h =
          case numeric(val) do
            nil -> 0.0
            v -> v / max_v * 40
          end

        %{
          x: 10 + li * group_w + si * bar_w,
          y: 44 - h,
          w: bar_w,
          h: h,
          fill: tone_fill(Enum.at(tones, si) || :primary),
          label_i: li,
          label: label
        }
      end

    label_marks =
      Enum.with_index(labels, fn label, li ->
        %{x: 10 + li * group_w + group_w * 0.35, text: label}
      end)

    aria =
      cond do
        assigns.label not in [nil, ""] -> assigns.label
        labels == [] -> "no categories"
        true -> Enum.join(labels, ", ")
      end

    assigns =
      assigns
      |> assign(:empty?, empty?)
      |> assign(:bars, bars)
      |> assign(:label_marks, label_marks)
      |> assign(:aria_label, aria)

    ~H"""
    <div class={["w-full", @class]} {@rest}>
      <p :if={@empty?} class="font-mono text-xs text-on-surface-variant">{display_value(nil)}</p>
      <svg
        :if={!@empty?}
        viewBox="0 0 100 56"
        class="w-full h-28"
        role="img"
        aria-label={@aria_label}
      >
        <rect
          :for={bar <- @bars}
          x={bar.x}
          y={bar.y}
          width={bar.w}
          height={bar.h}
          fill={bar.fill}
        />
        <text
          :for={mark <- @label_marks}
          x={mark.x}
          y="52"
          text-anchor="middle"
          fill="var(--md-sys-color-on-surface-variant)"
          font-size="5"
          font-family="var(--font-mono)"
          aria-hidden="true"
        >
          {mark.text}
        </text>
      </svg>
    </div>
    """
  end

  # Flat `[n | nil]` → single series. Nested lists stay multi-series.
  defp normalize_bar_series([]), do: []

  defp normalize_bar_series(series) do
    if Enum.all?(series, &(is_number(&1) or is_nil(&1))) do
      [series]
    else
      series
    end
  end

  # ---------------------------------------------------------------------------
  # status_dot
  # ---------------------------------------------------------------------------

  @doc """
  Status indicator dot with optional label.

  Accepts either a paint `tone` atom (`@tone_values`) **or** a `status`
  label resolved via `status_tone/1`. `tone` wins when both are set.
  """
  attr :tone, :atom, doc: "Explicit tone atom; wins over status.", values: @tone_values
  attr :status, :any, doc: "Raw label via status_tone/1 (completed→:success).", default: nil
  attr :label, :string, doc: "Text beside the dot; defaults to status string.", default: nil
  attr :class, :string, doc: "Extra classes on the outer span.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer span."

  def status_dot(assigns) do
    tone = resolve_tone(assigns)

    assigns =
      assigns
      |> assign(:resolved_tone, tone)
      |> assign(:dot_class, tone_bg_class(tone))
      |> assign(:shown_label, assigns.label || status_label(assigns))

    ~H"""
    <span class={["inline-flex items-center gap-2", @class]} {@rest}>
      <span class={["inline-block w-2 h-2 shrink-0", @dot_class]} aria-hidden="true" />
      <span :if={@shown_label} class={["font-body text-sm", tone_class(@resolved_tone)]}>
        {@shown_label}
      </span>
    </span>
    """
  end

  defp status_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp status_label(%{status: status}) when not is_nil(status), do: to_string(status)
  defp status_label(_), do: nil

  # ---------------------------------------------------------------------------
  # data_table
  # ---------------------------------------------------------------------------

  @doc """
  Simple data table. `cols` is a list of `%{key:, label:}` (or atom keys).
  `rows` is a list of maps. Cell values of `nil` render as `—`.
  """
  attr :cols, :list, doc: "Columns as %{key,label} (or bare atom keys).", default: []
  attr :rows, :list, doc: "Row maps; nil cells → em dash.", default: []

  attr :state, :atom,
    doc: ":ok | :loading | :error — remote fetch; loading ≠ empty table.",
    default: :ok,
    values: [:ok, :loading, :error]

  attr :error, :string, doc: "Failure copy when state=:error.", default: nil
  attr :class, :string, doc: "Extra classes on the outer wrapper.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the outer wrapper."
  slot :empty, doc: "shown when rows is empty"

  def data_table(assigns) do
    empty? = (assigns.rows || []) == [] or (assigns.cols || []) == []
    assigns = assign(assigns, :empty?, empty?)

    ~H"""
    <div class={["w-full overflow-x-auto", @class]} {@rest}>
      <.fetch_state :if={@state != :ok} state={@state} error={@error} class="py-4" />
      <div :if={@state == :ok and @empty?} class="font-mono text-xs text-on-surface-variant py-4">
        <span :if={@empty == []}>{display_value(nil)}</span>
        {render_slot(@empty)}
      </div>
      <table :if={@state == :ok and !@empty?} class="min-w-full text-sm border-collapse">
        <thead>
          <tr class="border-b border-outline-variant">
            <th
              :for={col <- @cols}
              scope="col"
              class="type-chrome text-on-surface-variant text-left px-3 py-2 font-normal"
            >
              {col_label(col)}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            class="border-b border-outline-variant/40 hover:bg-surface-container-low"
          >
            <td :for={col <- @cols} class="font-mono text-xs text-on-surface px-3 py-2 tabular-nums">
              {display_value(row_value(row, col))}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp col_label(%{label: label}), do: label
  defp col_label(%{"label" => label}), do: label
  defp col_label(%{key: key}), do: key |> to_string() |> String.replace("_", " ")
  defp col_label(key) when is_atom(key), do: key |> to_string() |> String.replace("_", " ")
  defp col_label(other), do: to_string(other)

  defp col_key(%{key: key}), do: key
  defp col_key(%{"key" => key}), do: key
  defp col_key(key), do: key

  defp row_value(row, col) when is_map(row) do
    key = col_key(col)

    cond do
      Map.has_key?(row, key) ->
        Map.get(row, key)

      is_atom(key) and Map.has_key?(row, to_string(key)) ->
        Map.get(row, to_string(key))

      is_binary(key) ->
        atom_key = String.to_existing_atom(key)
        Map.get(row, atom_key)

      true ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp row_value(_, _), do: nil

  # ---------------------------------------------------------------------------
  # kv_row
  # ---------------------------------------------------------------------------

  @doc """
  Key/value row for config surfaces. `value` of `nil` → `—`.
  """
  attr :label, :string, doc: "Key caption (required).", required: true
  attr :value, :any, doc: "Displayed value; nil → em dash.", default: nil
  attr :source, :string, doc: "Optional provenance chip (project, unset).", default: nil
  attr :note, :string, doc: "Optional trailing note.", default: nil
  attr :class, :string, doc: "Extra classes on the row.", default: nil
  attr :rest, :global, doc: "Passthrough HTML attrs on the row."

  def kv_row(assigns) do
    assigns = assign(assigns, :display, display_value(assigns.value))

    # Outer establishes the container; grid + cq-* live on the child — never on
    # the same node as `cq` (queries apply to descendants, not the container).
    ~H"""
    <div class={["cq", @class]} {@rest}>
      <div class={[
        "grid grid-cols-1 gap-1 py-2 border-b border-outline-variant/40 items-baseline",
        "cq-sm-grid-cols-kv-2 cq-sm-gap-3 cq-md-grid-cols-kv"
      ]}>
        <span class="type-label text-on-surface-variant">{@label}</span>
        <span class="font-mono text-sm text-on-surface tabular-nums">
          {@display}
          <span :if={@note} class="ml-2 font-body text-xs text-on-surface-variant">{@note}</span>
        </span>
        <span :if={@source} class="type-chrome-dense text-on-surface-variant">{@source}</span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp numeric(nil), do: nil
  defp numeric(n) when is_number(n), do: n * 1.0

  defp numeric(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp numeric(_), do: nil
end
