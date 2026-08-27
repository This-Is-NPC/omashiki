defmodule Omashiki.Plugin.Loader do
  @moduledoc "Loads and indexes declarative plugin manifests from `plugins/*.toml`."

  alias Omashiki.Config.Error
  alias Omashiki.Plugin.Manifest

  def load!(plugins_dir) when is_binary(plugins_dir) do
    unless File.dir?(plugins_dir) do
      raise Error, "plugins directory not found at #{plugins_dir}"
    end

    plugins_dir
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_file!/1)
    |> Map.new(fn manifest -> {manifest.name, manifest} end)
  end

  def fetch!(plugins, name) when is_map(plugins) do
    case Map.get(plugins, name) do
      %Manifest{} = manifest -> manifest
      nil -> raise Error, "plugins/#{name}.toml not found for preset plugin=#{inspect(name)}"
    end
  end

  def plugin_path(plugins_dir, name), do: Path.join(plugins_dir, "#{name}.toml")

  defp load_file!(path) do
    name = path |> Path.basename() |> Path.rootname(".toml")

    case File.read(path) do
      {:ok, contents} ->
        Manifest.parse!(name, path, contents)

      {:error, reason} ->
        raise Error, "#{path}: unreadable plugin file: #{inspect(reason)}"
    end
  end
end
