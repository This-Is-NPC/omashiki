defmodule Omashiki.Runtimes do
  @moduledoc """
  Runtime value helpers for job environment snapshots.
  """

  alias Omashiki.Config
  alias Omashiki.Isolation

  def docker_image(%Isolation{kind: "docker", config: config}) when is_map(config) do
    case Map.get(config, "image") || Map.get(config, :image) do
      image when is_binary(image) and image != "" -> image
      _ -> nil
    end
  end

  def docker_image(%{kind: "docker", config: config}) when is_map(config) do
    case Map.get(config, "image") || Map.get(config, :image) do
      image when is_binary(image) and image != "" -> image
      _ -> nil
    end
  end

  def docker_image(_), do: nil

  def mounts(%Isolation{config: config}) when is_map(config) do
    case Map.get(config, "mounts") || Map.get(config, :mounts) do
      mounts when is_map(mounts) -> mounts
      _ -> %{}
    end
  end

  def mounts(%{config: config}) when is_map(config) do
    case Map.get(config, "mounts") || Map.get(config, :mounts) do
      mounts when is_map(mounts) -> mounts
      _ -> %{}
    end
  end

  def mounts(_), do: %{}

  @doc "Resolved cache groups attached to a runtime, in declaration order."
  def cache_groups(%{config: config}) when is_map(config) do
    names =
      cond do
        Map.has_key?(config, "caches") -> Map.get(config, "caches")
        Map.has_key?(config, :caches) -> Map.get(config, :caches)
        Config.get_cache("global") -> ["global"]
        true -> []
      end

    names
    |> List.wrap()
    |> Enum.map(&Config.get_cache/1)
    |> Enum.reject(&is_nil/1)
  end

  def cache_groups(_), do: []

  def bootstrap(%{config: config}) when is_map(config) do
    Map.get(config, "bootstrap") || Map.get(config, :bootstrap)
  end

  def bootstrap(_), do: nil

  def bootstrap_timeout_ms(%{config: config}) when is_map(config) do
    Map.get(config, "bootstrap_timeout_ms") || Map.get(config, :bootstrap_timeout_ms)
  end

  def bootstrap_timeout_ms(_), do: nil
end
