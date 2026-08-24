defmodule Omashiki.SupplyChain.Paths do
  @moduledoc "Realpath resolution used to enforce local-source containment."

  @doc "Resolve an existing path while following symlinks in every component."
  def real(path) when is_binary(path), do: resolve(Path.expand(path), MapSet.new())
  def real(_), do: {:error, :invalid_path}

  defp resolve(path, seen) do
    if MapSet.member?(seen, path) do
      {:error, :symlink_loop}
    else
      resolve_components(Path.split(path), "/", MapSet.put(seen, path))
    end
  end

  defp resolve_components([], current, _seen), do: {:ok, current}
  defp resolve_components(["/" | rest], _current, seen), do: resolve_components(rest, "/", seen)

  defp resolve_components([component | rest], current, seen) do
    next = if current == "/", do: "/" <> component, else: Path.join(current, component)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next),
             target = Path.expand(target, current),
             remainder <- join_remainder(rest),
             {:ok, resolved} <- resolve(Path.join(target, remainder), seen) do
          {:ok, resolved}
        end

      {:ok, _} ->
        resolve_components(rest, next, seen)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_remainder([]), do: "."
  defp join_remainder(parts), do: Path.join(parts)
end
