defmodule Omashiki.Harnesses do
  @moduledoc "Configured preset and adapter registry."

  alias Omashiki.Config.Error
  alias Omashiki.Harness.LaunchPlan
  alias Omashiki.Isolation
  alias Omashiki.Plugin.Preset

  @default_adapters %{
    "opencode" => Omashiki.Harness.OpenCode,
    "claude-code" => Omashiki.Harness.ClaudeCode,
    "codex" => Omashiki.Harness.Codex,
    "jcode" => Omashiki.Harness.Jcode,
    "pi" => Omashiki.Harness.Pi
  }

  @adapter_callbacks [{:validate_options, 1}, {:launch_plan, 1}, {:prepare, 2}, {:invoke, 2}]
  @preset_fields ~w(plugin options)
  @legacy_preset_fields ~w(adapter runtime image)

  def adapter(%Preset{adapter: adapter}), do: adapter
  def adapter(%{adapter: adapter}) when is_atom(adapter), do: adapter
  def adapter(%{adapter: key}) when is_binary(key), do: fetch_adapter!(key)
  def adapter(%{preset: profile}), do: adapter(profile)
  def adapter(%{"preset" => profile}), do: profile |> profile_from_snapshot!() |> adapter()
  def adapter(%{key: key}) when is_binary(key), do: fetch_adapter!(key)

  def adapter(environment),
    do: raise(ArgumentError, "environment has no resolved plugin: #{inspect(environment)}")

  def adapter_key(%Preset{adapter_key: key}), do: key

  def profile(%{preset: %Preset{} = profile}), do: profile
  def profile(%{preset: profile}) when is_map(profile), do: profile_from_snapshot!(profile)
  def profile(%{"preset" => profile}) when is_map(profile), do: profile_from_snapshot!(profile)
  def profile(_), do: raise(ArgumentError, "environment has no resolved preset")

  def build!(section) when is_map(section) do
    section
    |> Enum.map(fn {name, attrs} -> build_preset_base!(name, attrs) end)
    |> Enum.sort_by(& &1.name)
  end

  def build!(_), do: raise(Error, "presets must be a table")

  def finalize_preset!(%Preset{} = base, isolation_kind, image, where) do
    runtime = %Isolation{
      key: base.name,
      kind: isolation_kind,
      config: %{"image" => image},
      status: "active"
    }

    preset = %{base | runtime: runtime, launch_plan: nil}

    launch_plan =
      case preset.adapter.launch_plan(preset) do
        {:ok, %LaunchPlan{} = plan} ->
          validate_launch_plan!(plan, where)
          plan

        {:ok, other} ->
          raise Error, "#{where}: adapter returned invalid launch plan #{inspect(other)}"

        {:error, reason} ->
          raise Error, "#{where}: invalid adapter launch plan: #{format(reason)}"

        other ->
          raise Error, "#{where}: adapter returned invalid launch plan #{inspect(other)}"
      end

    %{preset | launch_plan: launch_plan}
  end

  defp build_preset_base!(name, attrs) do
    where = "presets.#{name}"
    validate_name!(name, where)
    attrs = require_table!(attrs, where)
    reject_legacy_preset_fields!(attrs, where)
    reject_unknown!(attrs, @preset_fields, where)

    adapter_key = require_string!(attrs, "plugin", where)
    options = Map.get(attrs, "options", %{})
    unless is_map(options), do: raise(Error, "#{where}.options must be a table")

    adapter = validate_adapter!(adapter_key, options, where)

    %Preset{
      name: name,
      adapter: adapter,
      adapter_key: adapter_key,
      options: options,
      runtime: nil,
      launch_plan: nil
    }
  rescue
    error in [ArgumentError] ->
      raise Error, "invalid preset #{inspect(name)}: #{error.message}"
  end

  defp reject_legacy_preset_fields!(attrs, where) do
    Enum.each(@legacy_preset_fields, fn key ->
      if Map.has_key?(attrs, key), do: raise(Error, "#{where}: unknown field #{inspect(key)}")
    end)
  end

  defp validate_adapter!(key, options, where) do
    adapter = fetch_adapter!(key)
    Code.ensure_loaded(adapter)

    unless Enum.all?(@adapter_callbacks, fn {function, arity} ->
             function_exported?(adapter, function, arity)
           end) do
      raise Error, "#{where}.plugin #{inspect(key)} does not implement Omashiki.Harness.Adapter"
    end

    case adapter.validate_options(options) do
      :ok -> adapter
      {:error, reason} -> raise Error, "#{where}.options are invalid: #{format(reason)}"
      other -> raise Error, "#{where}.plugin returned invalid option result #{inspect(other)}"
    end
  end

  defp fetch_adapter!(key) do
    adapters = Map.merge(@default_adapters, Application.get_env(:omashiki, :harness_adapters, %{}))

    case Map.get(adapters, key) do
      module when is_atom(module) -> module
      nil -> raise ArgumentError, "unknown plugin #{inspect(key)}"
    end
  end

  defp profile_from_snapshot!(%{
         "name" => name,
         "adapter_key" => adapter_key,
         "options" => options,
         "runtime" => runtime,
         "launch_plan" => launch_plan
       }) do
    runtime = runtime_from_snapshot(runtime)
    launch_plan = launch_plan_from_snapshot(launch_plan, runtime)

    %Preset{
      name: name,
      adapter: fetch_adapter!(adapter_key),
      adapter_key: adapter_key,
      options: options,
      runtime: runtime,
      launch_plan: launch_plan
    }
  end

  defp profile_from_snapshot!(profile),
    do: raise(ArgumentError, "invalid resolved preset #{inspect(profile)}")

  defp runtime_from_snapshot(%Isolation{} = runtime), do: runtime

  defp runtime_from_snapshot(%{"kind" => kind, "config" => config}),
    do: %Isolation{key: nil, kind: kind, config: config, status: "active"}

  defp runtime_from_snapshot(runtime), do: runtime

  defp launch_plan_from_snapshot(%LaunchPlan{} = plan, _runtime), do: plan

  defp launch_plan_from_snapshot(%{} = plan, runtime) do
    %LaunchPlan{
      runtime: runtime,
      transport: Map.get(plan, "transport", %{}),
      startup: Map.get(plan, "startup"),
      readiness: Map.get(plan, "readiness"),
      secret: Map.get(plan, "secret"),
      environment: Map.get(plan, "environment", []),
      llm_egress: normalize_egress(Map.get(plan, "llm_egress"))
    }
  end

  defp normalize_egress("gateway"), do: :gateway
  defp normalize_egress("engine"), do: :engine
  defp normalize_egress(value), do: value

  defp validate_launch_plan!(%LaunchPlan{runtime: runtime, transport: transport}, where) do
    unless runtime.kind in Isolation.kinds(),
      do: raise(Error, "#{where}: adapter launch plan has unsupported runtime #{inspect(runtime.kind)}")

    if runtime.kind == "docker" and not is_binary(Omashiki.Runtimes.docker_image(runtime)) do
      raise Error, "#{where}: Docker launch plan requires an image"
    end

    kind = Map.get(transport, "kind", Map.get(transport, :kind))

    unless kind in ["http", "cli", :http, :cli],
      do: raise(Error, "#{where}: adapter launch plan has unsupported transport #{inspect(kind)}")

    if kind in ["http", :http] do
      port = Map.get(transport, "port", Map.get(transport, :port))

      unless is_integer(port) and port > 0 and port <= 65_535,
        do: raise(Error, "#{where}: HTTP transport requires a valid port")
    end

    :ok
  end

  defp require_table!(attrs, _where) when is_map(attrs), do: stringify_keys(attrs)
  defp require_table!(_, where), do: raise(Error, "#{where} must be a table")

  defp require_string!(attrs, key, where) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise Error, "#{where}: missing required field #{inspect(key)}"
    end
  end

  defp reject_unknown!(attrs, allowed, where) do
    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> raise Error, "#{where}: unknown fields #{inspect(Enum.sort(unknown))}"
    end
  end

  defp validate_name!(name, where) do
    unless is_binary(name) and Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, name),
      do: raise(Error, "#{where} name must be kebab-case")
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
