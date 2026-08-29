defmodule Omashiki.Presets do
  @moduledoc "Configured preset registry backed by declarative plugin manifests."

  alias Omashiki.Config.Error
  alias Omashiki.Harness.LaunchPlan
  alias Omashiki.Plugin.{Interpreter, Loader, Manifest}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Runtime.Spec

  @adapter Omashiki.Plugin.Interpreter
  @preset_fields ~w(plugin options)
  @legacy_preset_fields ~w(adapter runtime image)
  @snapshot_fields ~w(name plugin options runtime launch_plan manifest)
  @launch_plan_fields ~w(runtime transport startup readiness secret environment manifest llm_egress)

  def adapter(%Preset{adapter: adapter}), do: adapter
  def adapter(%{adapter: adapter}) when is_atom(adapter), do: adapter
  def adapter(%{preset: %Preset{} = profile}), do: adapter(profile)

  def adapter(%{preset: profile, runtime: runtime}) when is_map(profile),
    do: profile_from_snapshot!(profile, runtime) |> adapter()

  def adapter(%{"preset" => profile, "runtime" => runtime}) when is_map(profile),
    do: profile_from_snapshot!(profile, runtime) |> adapter()

  def adapter(environment),
    do: raise(ArgumentError, "environment has no resolved plugin: #{inspect(environment)}")

  def plugin(%Preset{plugin: key}), do: key

  def profile(%{preset: %Preset{} = profile}), do: profile

  def profile(%{preset: profile, runtime: runtime}) when is_map(profile),
    do: profile_from_snapshot!(profile, runtime)

  def profile(%{"preset" => profile, "runtime" => runtime}) when is_map(profile),
    do: profile_from_snapshot!(profile, runtime)

  def profile(_), do: raise(ArgumentError, "environment has no resolved preset")

  def build!(section, plugins) when is_map(section) do
    section
    |> Enum.map(fn {name, attrs} -> build_preset_base!(name, attrs, plugins) end)
    |> Enum.sort_by(& &1.name)
  end

  def build!(_, _), do: raise(Error, "presets must be a table")

  def finalize_preset!(%Preset{} = base, %Spec{} = runtime, where) do
    preset = %{base | runtime: runtime, launch_plan: nil}

    launch_plan =
      case Interpreter.launch_plan(preset) do
        {:ok, %LaunchPlan{} = plan} ->
          validate_launch_plan!(plan, runtime, where)
          plan

        {:ok, other} ->
          raise Error, "#{where}: plugin returned invalid launch plan #{inspect(other)}"

        {:error, reason} ->
          raise Error, "#{where}: invalid plugin launch plan: #{format(reason)}"

        other ->
          raise Error, "#{where}: plugin returned invalid launch plan #{inspect(other)}"
      end

    %{preset | launch_plan: launch_plan}
  end

  defp build_preset_base!(name, attrs, plugins) do
    where = "presets.#{name}"
    validate_name!(name, where)
    attrs = require_table!(attrs, where)
    reject_legacy_preset_fields!(attrs, where)
    reject_unknown!(attrs, @preset_fields, where)

    plugin = require_string!(attrs, "plugin", where)
    options = Map.get(attrs, "options", %{})
    unless is_map(options), do: raise(Error, "#{where}.options must be a table")

    manifest = Loader.fetch!(plugins, plugin)
    validate_options!(manifest, options, where)

    %Preset{
      name: name,
      adapter: @adapter,
      plugin: plugin,
      options: options,
      runtime: nil,
      launch_plan: nil,
      manifest: manifest
    }
  rescue
    error in [ArgumentError] ->
      raise Error, "invalid preset #{inspect(name)}: #{error.message}"
  end

  defp validate_options!(manifest, options, where) do
    unless is_map(options), do: raise(Error, "#{where}.options must be a table")

    case @adapter.validate_options(manifest, options) do
      :ok ->
        :ok

      {:error, {:unknown_options, keys}} ->
        raise Error, "#{where}.options unknown field #{inspect(hd(keys))}"

      {:error, reason} ->
        raise Error, "#{where}.options are invalid: #{format(reason)}"

      other ->
        raise Error, "#{where}.plugin returned invalid option result #{inspect(other)}"
    end
  end

  defp profile_from_snapshot!(
         %{
           "name" => name,
           "plugin" => plugin,
           "options" => options,
           "runtime" => snapshot_runtime
         } = profile,
         runtime
       ) do
    unknown = Map.keys(profile) -- @snapshot_fields

    if unknown != [] do
      raise ArgumentError, "invalid resolved preset #{inspect(profile)}"
    end

    runtime = runtime_from_snapshot(runtime)
    snapshot_runtime = runtime_from_snapshot(snapshot_runtime)

    if snapshot_runtime != runtime do
      raise ArgumentError, "resolved preset runtime does not match environment runtime"
    end

    launch_plan = launch_plan_from_snapshot(Map.get(profile, "launch_plan"), runtime)
    manifest = manifest_from_snapshot(Map.get(profile, "manifest"))

    %Preset{
      name: name,
      adapter: @adapter,
      plugin: plugin,
      options: options,
      runtime: runtime,
      launch_plan: launch_plan,
      manifest: manifest
    }
  end

  defp profile_from_snapshot!(profile, _runtime),
    do: raise(ArgumentError, "invalid resolved preset #{inspect(profile)}")

  defp manifest_from_snapshot(nil), do: nil
  defp manifest_from_snapshot(%Manifest{} = manifest), do: manifest
  defp manifest_from_snapshot(map) when is_map(map), do: Manifest.from_snapshot(map)

  defp runtime_from_snapshot(%Spec{handler: handler} = runtime) when is_binary(handler),
    do: runtime

  defp runtime_from_snapshot(
         %{
           "name" => name,
           "backend" => backend,
           "handler" => handler,
           "distribution" => distribution,
           "plugin" => plugin,
           "image" => image
         } = runtime
       ) do
    if Map.keys(runtime) |> Enum.sort() != ~w(backend distribution handler image name plugin) do
      raise ArgumentError, "invalid resolved runtime #{inspect(runtime)}"
    end

    %Spec{
      name: name,
      backend: backend,
      handler: handler,
      distribution: distribution,
      plugin: plugin,
      image: image
    }
  end

  defp runtime_from_snapshot(runtime),
    do: raise(ArgumentError, "invalid resolved runtime #{inspect(runtime)}")

  defp launch_plan_from_snapshot(%LaunchPlan{runtime: runtime} = plan, runtime), do: plan

  defp launch_plan_from_snapshot(%{"runtime" => snapshot_runtime} = plan, runtime) do
    unknown = Map.keys(plan) -- @launch_plan_fields

    if unknown != [] do
      raise ArgumentError, "invalid resolved launch plan #{inspect(plan)}"
    end

    snapshot_runtime = runtime_from_snapshot(snapshot_runtime)

    if snapshot_runtime != runtime do
      raise ArgumentError, "resolved launch plan runtime does not match environment runtime"
    end

    %LaunchPlan{
      runtime: runtime,
      transport: Map.get(plan, "transport", %{}),
      startup: Map.get(plan, "startup"),
      readiness: Map.get(plan, "readiness"),
      secret: Map.get(plan, "secret"),
      environment: Map.get(plan, "environment", []),
      manifest: Map.get(plan, "manifest"),
      llm_egress: normalize_egress(Map.get(plan, "llm_egress"))
    }
  end

  defp launch_plan_from_snapshot(plan, _),
    do: raise(ArgumentError, "invalid resolved launch plan #{inspect(plan)}")

  defp normalize_egress("gateway"), do: :gateway
  defp normalize_egress("engine"), do: :engine
  defp normalize_egress(value), do: value

  defp validate_launch_plan!(
         %LaunchPlan{runtime: plan_runtime, transport: transport},
         runtime,
         where
       ) do
    unless plan_runtime == runtime do
      raise Error, "#{where}: plugin launch plan runtime does not match selected runtime"
    end

    unless runtime.backend == "docker",
      do:
        raise(
          Error,
          "#{where}: plugin launch plan has unsupported backend #{inspect(runtime.backend)}"
        )

    unless runtime.handler in ["runc", "kata"],
      do:
        raise(
          Error,
          "#{where}: plugin launch plan has unsupported Docker runtime handler #{inspect(runtime.handler)}"
        )

    if not is_binary(Omashiki.Runtimes.image(runtime)) do
      raise Error, "#{where}: Docker launch plan requires an image"
    end

    kind = Map.get(transport, "kind", Map.get(transport, :kind))

    unless kind in ["http", "cli", :http, :cli],
      do: raise(Error, "#{where}: plugin launch plan has unsupported transport #{inspect(kind)}")

    if kind in ["http", :http] do
      port = Map.get(transport, "port", Map.get(transport, :port))

      unless is_integer(port) and port > 0 and port <= 65_535,
        do: raise(Error, "#{where}: HTTP transport requires a valid port")
    end

    :ok
  end

  defp reject_legacy_preset_fields!(attrs, where) do
    Enum.each(@legacy_preset_fields, fn key ->
      if Map.has_key?(attrs, key), do: raise(Error, "#{where}: unknown field #{inspect(key)}")
    end)
  end

  defp require_table!(attrs, _where) when is_map(attrs), do: stringify_keys(attrs)
  defp require_table!(_, where), do: raise(Error, "#{where} must be a table")

  defp require_string!(attrs, key, where) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise Error, "#{where}.#{key} must be a non-empty string"
    end
  end

  defp reject_unknown!(attrs, allowed, where) do
    unknown = Map.keys(attrs) -- allowed
    if unknown != [], do: raise(Error, "#{where}: unknown field #{inspect(hd(unknown))}")
  end

  defp validate_name!(name, where) do
    unless is_binary(name) and Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, name),
      do: raise(Error, "#{where} has an invalid name")
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
