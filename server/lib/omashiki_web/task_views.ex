defmodule OmashikiWeb.TaskViews.View do
  @moduledoc "One validated task view. Every value only selects what the Home screen renders."

  @enforce_keys [:name, :title]
  defstruct [
    :name,
    :title,
    layout: :list,
    fields: [],
    filter: %{},
    sort: {:inserted_at, :desc},
    group_by: nil,
    limit: 100,
    blocks: [],
    show_idle_workers: true,
    show_stale_workers: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          layout: :list | :board | :graph,
          fields: [String.t()],
          filter: map(),
          sort: {atom(), :asc | :desc},
          group_by: atom() | nil,
          limit: pos_integer(),
          blocks: [atom()]
        }
end

defmodule OmashikiWeb.TaskViews do
  @moduledoc """
  Display-only task views declared in the operator's `ui.toml`.

  The file only chooses what the Home screen renders: fields, filters, sort
  order, grouping, layout, and summary blocks. It declares no action. Nothing
  outside the web layer reads it — admission, dispatch, workers, and the
  `omashiki.toml` registry never see it — so a broken file cannot change a job
  or stop the house from booting. The screen keeps the last valid views and
  shows every problem found.

  Path resolution, first match wins: the `:ui_config_path` application env,
  `OMASHIKI_UI_CONFIG`, `$XDG_CONFIG_HOME/omashiki/ui.toml`, then
  `~/.config/omashiki/ui.toml`. Without a file the built-in views apply.
  """

  alias Omashiki.Jobs.Api
  alias OmashikiWeb.TaskViews.{Rows, View}

  @top_keys ~w(default_view views)
  @view_keys ~w(name title layout fields filter sort group_by limit blocks
                show_idle_workers show_stale_workers)
  @filter_keys ~w(status environment repository priority worker since)
  @layouts %{"list" => :list, "board" => :board, "graph" => :graph}
  @sorts %{
    "submitted" => :inserted_at,
    "started" => :started_at,
    "finished" => :finished_at,
    "priority" => :priority
  }
  @group_keys %{
    "status" => :status,
    "environment" => :environment,
    "repository" => :repository,
    "plugin" => :plugin,
    "sink" => :sink,
    "priority" => :priority,
    "worker" => :worker
  }
  @blocks %{"status_counts" => :status_counts, "slots" => :slots, "workers" => :workers}
  @duration_units %{"m" => 60, "h" => 3_600, "d" => 86_400}
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]{0,39}$/
  @duration_pattern ~r/^([1-9][0-9]{0,4})(m|h|d)$/
  @default_limit 100
  @max_limit 500
  @max_title 60

  @builtin """
  default_view = "board"

  [[views]]
  name = "board"
  title = "Board"
  layout = "board"
  group_by = "status"
  filter = { since = "24h" }
  fields = ["title", "environment", "worker", "step", "duration"]

  [[views]]
  name = "active"
  title = "Active"
  filter = { status = ["blocked", "queued", "provisioning", "running"] }
  fields = ["status", "title", "environment", "worker", "step", "wait", "duration"]
  blocks = ["status_counts", "slots", "workers"]

  [[views]]
  name = "finished"
  title = "Finished"
  filter = { status = ["succeeded", "failed", "cancelled"], since = "7d" }
  sort = "-finished"
  fields = ["status", "title", "environment", "duration", "finished", "result", "error"]

  [[views]]
  name = "fleet"
  title = "Fleet"
  layout = "graph"
  fields = ["title", "environment", "step", "duration"]
  """

  defstruct path: nil, digest: nil, source: :builtin, views: [], default_view: nil, errors: []

  @type t :: %__MODULE__{
          path: String.t(),
          digest: binary() | :missing | {:error, term()} | nil,
          source: :builtin | :file,
          views: [View.t()],
          default_view: String.t() | nil,
          errors: [String.t()]
        }

  def max_limit, do: @max_limit

  @doc "Resolve the views file path."
  def path do
    cond do
      configured = Application.get_env(:omashiki, :ui_config_path) ->
        Path.expand(configured)

      configured = present(System.get_env("OMASHIKI_UI_CONFIG")) ->
        Path.expand(configured)

      config_home = present(System.get_env("XDG_CONFIG_HOME")) ->
        Path.join([config_home, "omashiki", "ui.toml"])

      true ->
        Path.expand("~/.config/omashiki/ui.toml")
    end
  end

  @doc "The views that apply while no views file exists."
  def builtin do
    {:ok, views, default_view} = parse(@builtin)
    {views, default_view}
  end

  @doc "Read the views file at `path`, falling back to the built-in views."
  def load(path \\ path()) do
    {views, default_view} = builtin()
    refresh(%__MODULE__{path: path, views: views, default_view: default_view})
  end

  @doc """
  Re-read the file when its content changed. A rejected file keeps the views
  that were already in use and records why it was rejected.
  """
  def refresh(%__MODULE__{path: path} = state) do
    {digest, contents} =
      case File.read(path) do
        {:ok, contents} -> {:crypto.hash(:sha256, contents), contents}
        {:error, :enoent} -> {:missing, nil}
        {:error, reason} -> {{:error, reason}, nil}
      end

    if digest == state.digest,
      do: state,
      else: apply_read(%{state | digest: digest}, contents)
  end

  defp apply_read(%__MODULE__{digest: :missing} = state, _contents) do
    {views, default_view} = builtin()
    %{state | source: :builtin, views: views, default_view: default_view, errors: []}
  end

  defp apply_read(%__MODULE__{digest: {:error, reason}} = state, _contents),
    do: %{state | errors: ["cannot read #{state.path}: #{:file.format_error(reason)}"]}

  defp apply_read(%__MODULE__{} = state, contents) do
    case parse(contents) do
      {:ok, views, default_view} ->
        %{state | source: :file, views: views, default_view: default_view, errors: []}

      {:error, errors} ->
        %{state | errors: errors}
    end
  end

  @doc """
  Return the named view, or the default view. `{:fallback, view}` means the
  name is not declared and the default view was chosen in its place.
  """
  def find(%__MODULE__{} = state, nil), do: {:ok, default_view(state)}

  def find(%__MODULE__{views: views} = state, name) do
    case Enum.find(views, &(&1.name == name)) do
      nil -> {:fallback, default_view(state)}
      view -> {:ok, view}
    end
  end

  defp default_view(%__MODULE__{views: views, default_view: name}),
    do: Enum.find(views, hd(views), &(&1.name == name))

  @doc "Parse and validate views TOML. An error lists every problem, not only the first."
  def parse(contents) when is_binary(contents) do
    case Toml.decode(contents) do
      {:ok, document} -> validate(document)
      {:error, {:invalid_toml, reason}} -> {:error, ["invalid TOML: #{format_reason(reason)}"]}
      {:error, reason} -> {:error, ["invalid TOML: #{format_reason(reason)}"]}
    end
  end

  defp validate(document) do
    {views, view_errors} = validate_views(Map.get(document, "views"))

    # A default that names a rejected view is reported through that view.
    default_result =
      if view_errors == [],
        do: validate_default(Map.get(document, "default_view"), views),
        else: {:ok, nil}

    errors =
      unknown_keys(document, @top_keys, "file") ++ view_errors ++ error_list(default_result)

    case {errors, default_result} do
      {[], {:ok, default_view}} -> {:ok, views, default_view}
      _ -> {:error, errors}
    end
  end

  defp validate_default(nil, [%View{name: name} | _]), do: {:ok, name}

  defp validate_default(name, views) when is_binary(name) do
    if Enum.any?(views, &(&1.name == name)),
      do: {:ok, name},
      else: {:error, ~s(default_view: "#{name}" does not name a declared view)}
  end

  defp validate_default(_name, _views), do: {:error, "default_view: must be a string"}

  defp validate_views(entries) when is_list(entries) and entries != [] do
    results =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} -> validate_view(entry, index) end)

    views = for {:ok, view} <- results, do: view
    errors = for {:error, messages} <- results, message <- messages, do: message

    duplicates =
      views
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> ~s(views: name "#{name}" is declared more than once) end)
      |> Enum.sort()

    {views, errors ++ duplicates}
  end

  defp validate_views(entries) when is_nil(entries) or entries == [],
    do: {[], ["views: declare at least one [[views]] table"]}

  defp validate_views(_entries),
    do: {[], ["views: must be an array of tables written as [[views]]"]}

  defp validate_view(entry, index) when is_map(entry) do
    where = view_where(entry, index)
    layout = validate_layout(entry["layout"])

    results = [
      name: validate_name(entry["name"]),
      title: validate_title(entry["title"], entry["name"]),
      layout: layout,
      fields: validate_fields(entry["fields"]),
      filter: validate_filter(entry["filter"]),
      sort: validate_sort(entry["sort"]),
      group_by: validate_group_by(entry["group_by"], ok_value(layout, :list)),
      limit: validate_limit(entry["limit"]),
      blocks: validate_blocks(entry["blocks"]),
      show_idle_workers: validate_graph_flag(entry["show_idle_workers"], ok_value(layout, :list)),
      show_stale_workers:
        validate_graph_flag(entry["show_stale_workers"], ok_value(layout, :list))
    ]

    value_errors =
      for {key, {:error, messages}} <- results,
          message <- List.wrap(messages),
          do: "#{where}: #{key}: #{message}"

    case unknown_keys(entry, @view_keys, where) ++ value_errors do
      [] -> {:ok, struct!(View, for({key, {:ok, value}} <- results, do: {key, value}))}
      errors -> {:error, errors}
    end
  end

  defp validate_view(_entry, index), do: {:error, ["views[#{index}]: must be a table"]}

  defp view_where(%{"name" => name}, index) when is_binary(name),
    do: ~s(views[#{index}] "#{name}")

  defp view_where(_entry, index), do: "views[#{index}]"

  defp validate_name(nil), do: {:error, "is required"}

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name),
      do: {:ok, name},
      else:
        {:error,
         "must start with a lowercase letter or digit, use only a-z, 0-9, _ and -, and have at most 40 characters"}
  end

  defp validate_name(_name), do: {:error, "must be a string"}

  defp validate_title(nil, name) when is_binary(name), do: {:ok, name}
  defp validate_title(nil, _name), do: {:ok, nil}

  defp validate_title(title, _name) when is_binary(title) do
    title = String.trim(title)

    cond do
      title == "" -> {:error, "must not be blank"}
      String.length(title) > @max_title -> {:error, "must have at most #{@max_title} characters"}
      true -> {:ok, title}
    end
  end

  defp validate_title(_title, _name), do: {:error, "must be a string"}

  defp validate_layout(nil), do: {:ok, :list}
  defp validate_layout(layout) when is_map_key(@layouts, layout), do: {:ok, @layouts[layout]}
  defp validate_layout(_layout), do: {:error, ~s(must be "list", "board", or "graph")}

  defp validate_fields(nil), do: {:ok, Rows.default_fields()}
  defp validate_fields([]), do: {:error, "must list at least one field"}

  defp validate_fields(fields) when is_list(fields) do
    if Enum.all?(fields, &is_binary/1) do
      unknown = for field <- fields, not Rows.field?(field), do: ~s(unknown field "#{field}")

      repeated =
        fields
        |> Enum.frequencies()
        |> Enum.filter(fn {_field, count} -> count > 1 end)
        |> Enum.map(fn {field, _count} -> ~s(field "#{field}" is listed more than once) end)
        |> Enum.sort()

      case unknown ++ repeated do
        [] -> {:ok, fields}
        messages -> {:error, messages}
      end
    else
      {:error, "must be a list of strings"}
    end
  end

  defp validate_fields(_fields), do: {:error, "must be a list of strings"}

  defp validate_filter(nil), do: {:ok, %{}}

  defp validate_filter(filter) when is_map(filter) do
    results = for {key, value} <- filter, do: {key, validate_filter_value(key, value)}
    errors = for {key, {:error, message}} <- results, do: "#{key}: #{message}"

    if errors == [],
      do: {:ok, Map.new(for {_key, {:ok, pair}} <- results, do: pair)},
      else: {:error, Enum.sort(errors)}
  end

  defp validate_filter(_filter), do: {:error, "must be a table"}

  defp validate_filter_value("status", value) do
    statuses = Api.statuses()

    with {:ok, values} <- string_list(value) do
      case Enum.reject(values, &(&1 in statuses)) do
        [] ->
          {:ok, {:status, values}}

        unknown ->
          {:error,
           "unknown status #{Enum.map_join(unknown, ", ", &~s("#{&1}"))}; use #{Enum.join(statuses, ", ")}"}
      end
    end
  end

  defp validate_filter_value("environment", value), do: tagged(:environment, string_list(value))
  defp validate_filter_value("repository", value), do: tagged(:repository, string_list(value))
  defp validate_filter_value("worker", value), do: tagged(:worker, string_list(value))

  defp validate_filter_value("priority", value) do
    values = List.wrap(value)

    if values != [] and Enum.all?(values, &(is_integer(&1) and &1 in 0..3)),
      do: {:ok, {:priority, values}},
      else: {:error, "must be an integer from 0 through 3, or a list of them"}
  end

  defp validate_filter_value("since", value) when is_binary(value) do
    case Regex.run(@duration_pattern, value) do
      [_match, amount, unit] ->
        {:ok, {:since, String.to_integer(amount) * @duration_units[unit]}}

      nil ->
        {:error, ~s(must be a duration such as "30m", "24h", or "7d")}
    end
  end

  defp validate_filter_value("since", _value),
    do: {:error, ~s(must be a duration such as "30m", "24h", or "7d")}

  defp validate_filter_value(_key, _value),
    do: {:error, "unknown filter key; use #{Enum.join(@filter_keys, ", ")}"}

  defp validate_sort(nil), do: {:ok, {:inserted_at, :desc}}
  defp validate_sort("-" <> key) when is_map_key(@sorts, key), do: {:ok, {@sorts[key], :desc}}
  defp validate_sort(key) when is_map_key(@sorts, key), do: {:ok, {@sorts[key], :asc}}

  defp validate_sort(_sort),
    do:
      {:error,
       ~s(must be submitted, started, finished, or priority; prefix "-" for descending order)}

  # A graph is grouped by node already.
  defp validate_group_by(nil, :graph), do: {:ok, nil}
  defp validate_group_by(_key, :graph), do: {:error, "does not apply to the graph layout"}
  defp validate_group_by(nil, :board), do: {:ok, :status}
  defp validate_group_by(nil, _layout), do: {:ok, nil}

  defp validate_group_by(key, _layout) when is_map_key(@group_keys, key),
    do: {:ok, @group_keys[key]}

  defp validate_group_by(_key, _layout),
    do: {:error, "must be one of #{@group_keys |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}

  defp validate_limit(nil), do: {:ok, @default_limit}

  defp validate_limit(limit) when is_integer(limit) and limit >= 1 and limit <= @max_limit,
    do: {:ok, limit}

  defp validate_limit(_limit), do: {:error, "must be an integer from 1 through #{@max_limit}"}

  defp validate_blocks(nil), do: {:ok, []}

  defp validate_blocks(blocks) when is_list(blocks) do
    cond do
      not Enum.all?(blocks, &is_map_key(@blocks, &1)) ->
        {:error, "must list only #{@blocks |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}

      length(Enum.uniq(blocks)) != length(blocks) ->
        {:error, "must not list a block more than once"}

      true ->
        {:ok, Enum.map(blocks, &@blocks[&1])}
    end
  end

  defp validate_blocks(_blocks),
    do: {:error, "must list only #{@blocks |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}

  defp string_list(value) when is_binary(value), do: string_list([value])

  defp string_list(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, values},
      else: {:error, "must be a non-blank string or a list of them"}
  end

  defp string_list(_values), do: {:error, "must be a non-blank string or a list of them"}

  defp tagged(key, {:ok, values}), do: {:ok, {key, values}}
  defp tagged(_key, error), do: error

  defp unknown_keys(map, allowed, where) do
    map
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&~s(#{where}: unknown key "#{&1}"))
  end

  defp validate_graph_flag(nil, _layout), do: {:ok, true}
  defp validate_graph_flag(value, :graph) when is_boolean(value), do: {:ok, value}

  defp validate_graph_flag(value, _layout) when is_boolean(value),
    do: {:error, "applies only to the graph layout"}

  defp validate_graph_flag(_value, _layout), do: {:error, "must be true or false"}

  defp ok_value({:ok, value}, _default), do: value
  defp ok_value(_result, default), do: default

  defp error_list({:error, message}), do: [message]
  defp error_list(_result), do: []

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
