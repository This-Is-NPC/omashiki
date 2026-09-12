defmodule Omashiki.Maps do
  @moduledoc false

  def stringify_keys(%DateTime{} = value), do: value

  def stringify_keys(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, to_string(key), stringify_keys(value))
    end)
  end

  def stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value
end
