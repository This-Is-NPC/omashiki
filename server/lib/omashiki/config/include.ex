defmodule Omashiki.Config.Include do
  @moduledoc """
  Optional split of `omashiki.toml` into pieces.

  The root file may carry an `include` list. Each entry is a path relative to
  the root file's directory naming either a TOML file or a directory whose
  `*.toml` files are all loaded. Pieces are merged into the root map before
  anything is validated, so a split house and a single-file house build the
  same snapshot and the same digest.

  Rules, all of which fail the load rather than degrade:

    * `include` is only honoured on the root; a piece with its own `include`
      is an error (depth 1, no chains).
    * Paths stay inside the root's directory. No absolute paths, no `..`
      escapes, no URLs.
    * Only product sections may live in a piece: `identities`, `presets`,
      `environments`, `credentials`, `host_credentials`, `repositories`,
      `caches`. Infrastructure (`[app]`, `[db]`, `[auth]`, `[reload]`,
      `[runtimes]`, `[limits]`, `[nodes]`) stays on the root, which
      `runtime.exs` reads directly before `Config.load!/1` runs.
    * The same entry name declared in two places is a collision. There is no
      overlay: the root and every piece must each own distinct names.
  """

  alias Omashiki.Config.Error

  @splittable ~w(identities presets environments credentials host_credentials repositories caches)

  @doc "Sections a piece may declare."
  def splittable_sections, do: @splittable

  @doc """
  Merge the root map with every included piece.

  `root_path` locates the pieces; `map` is the decoded root. Returns the
  unified map with the `include` key removed.
  """
  @spec expand!(map(), String.t()) :: map()
  def expand!(%{} = map, root_path) when is_binary(root_path) do
    {entries, map} = Map.pop(map, "include", [])
    base_dir = root_path |> Path.expand() |> Path.dirname()

    entries
    |> validate_entries!()
    |> Enum.flat_map(&resolve!(&1, base_dir))
    |> Enum.reduce(map, fn piece_path, acc -> merge_piece!(acc, piece_path, base_dir) end)
  end

  defp validate_entries!(entries) when is_list(entries) do
    Enum.each(entries, fn
      entry when is_binary(entry) and entry != "" ->
        :ok

      other ->
        raise Error, "omashiki.toml: include entries must be strings, got #{inspect(other)}"
    end)

    entries
  end

  defp validate_entries!(other) do
    raise Error, "omashiki.toml: include must be an array of paths, got #{inspect(other)}"
  end

  # A file is itself; a directory is its `*.toml` files in name order so the
  # merge — and therefore the first collision reported — is deterministic.
  defp resolve!(entry, base_dir) do
    path = safe_join!(entry, base_dir)

    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(path, &1))

      true ->
        raise Error, "omashiki.toml: include #{inspect(entry)} not found at #{path}"
    end
  end

  defp safe_join!(entry, base_dir) do
    if String.contains?(entry, "://") or Path.type(entry) == :absolute do
      raise Error,
            "omashiki.toml: include #{inspect(entry)} must be a path relative to the config directory"
    end

    path = Path.expand(entry, base_dir)

    unless path == base_dir or String.starts_with?(path, base_dir <> "/") do
      raise Error, "omashiki.toml: include #{inspect(entry)} escapes the config directory"
    end

    path
  end

  defp merge_piece!(acc, piece_path, base_dir) do
    rel = Path.relative_to(piece_path, base_dir)

    piece =
      case Toml.decode_file(piece_path) do
        {:ok, decoded} -> decoded
        {:error, reason} -> raise Error, "include #{rel} is unreadable: #{inspect(reason)}"
      end

    if Map.has_key?(piece, "include") do
      raise Error, "include #{rel}: pieces may not include other pieces"
    end

    Enum.reduce(piece, acc, fn {section, entries}, acc ->
      unless section in @splittable do
        raise Error,
              "include #{rel}: [#{section}] must stay in omashiki.toml " <>
                "(pieces may declare #{Enum.join(@splittable, ", ")})"
      end

      unless is_map(entries) do
        raise Error, "include #{rel}: [#{section}] must be a table"
      end

      existing = Map.get(acc, section, %{})

      unless is_map(existing) do
        raise Error, "omashiki.toml [#{section}] must be a table"
      end

      merged =
        Map.merge(existing, entries, fn name, _left, _right ->
          raise Error,
                "[#{section}.#{name}] is declared more than once (include #{rel} collides)"
        end)

      Map.put(acc, section, merged)
    end)
  end
end
