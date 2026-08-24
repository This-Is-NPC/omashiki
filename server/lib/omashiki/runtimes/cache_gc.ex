defmodule Omashiki.Runtimes.CacheGc do
  @moduledoc """
  Safe filesystem backend for runtime cache snapshots and garbage collection.

  Cache groups are mounted into containers, so this module never removes the
  group directory itself. It only considers direct, non-symlink children as
  eviction units. Snapshot metadata is written atomically to a state directory
  outside the mounted cache payload.
  """

  require Logger

  alias Omashiki.Config
  alias Omashiki.Runtimes.{CacheGroup, CacheSnapshot}

  @cache_name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @metadata_version 1

  @doc "Resolves a configured cache group name or returns a readable error."
  def group(%CacheGroup{} = cache_group), do: {:ok, cache_group}

  def group(name) when is_binary(name) do
    case Config.get_cache(name) do
      %CacheGroup{} = cache_group -> {:ok, cache_group}
      nil -> {:error, {:unknown_group, name}}
    end
  end

  def group(other), do: {:error, {:invalid_group, other}}

  @doc "Returns the host state directory used for cache metadata."
  def metadata_root(opts \\ []) do
    (Keyword.get(opts, :metadata_root) ||
       System.get_env("OMASHIKI_CACHE_METADATA_ROOT") ||
       Path.join(System.user_home!(), ".local/state/omashiki/cache-metadata"))
    |> Path.expand()
  end

  @doc "Returns the configured cache root used for path containment checks."
  def cache_root do
    (System.get_env("OMASHIKI_CACHE_ROOT") ||
       Path.join(System.user_home!(), ".cache/omashiki"))
    |> Path.expand()
  end

  @doc "Records a host-side access timestamp without creating the payload dir."
  def touch(cache_group, opts \\ []) do
    with {:ok, %CacheGroup{name: name} = group} <- group(cache_group),
         {:ok, _host} <- safe_group_path(group),
         :ok <- metadata_outside_payload(group, opts),
         {:ok, metadata} <- read_metadata(name, opts) do
      now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
      write_metadata(name, Map.put(metadata, "last_accessed_at", now), opts)
    end
  end

  @doc "Builds and persists a snapshot for one cache group."
  def snapshot(cache_group, opts \\ []) do
    with {:ok, %CacheGroup{name: name} = group} <- group(cache_group),
         {:ok, host} <- safe_group_path(group),
         :ok <- metadata_outside_payload(group, opts),
         {:ok, metadata} <- read_metadata(name, opts) do
      {entries, errors} = scan_entries(host, metadata)
      size_bytes = Enum.reduce(entries, 0, &(&1.size_bytes + &2))
      captured_at = DateTime.utc_now(:microsecond)

      snapshot = %CacheSnapshot{
        group: name,
        host: host,
        size_bytes: size_bytes,
        max_size_mb: group.max_size_mb,
        last_accessed_at:
          metadata
          |> Map.get("last_accessed_at")
          |> parse_datetime()
          |> case do
            nil -> latest_datetime(Enum.map(entries, & &1.last_accessed_at))
            value -> value
          end,
        captured_at: captured_at,
        entries: entries,
        errors: errors
      }

      metadata = snapshot_metadata(snapshot, metadata)

      with :ok <- write_metadata(name, metadata, opts) do
        {:ok, snapshot}
      end
    end
  end

  @doc """
  Enforces `max_size_mb` by removing oldest top-level cache entries first.

  A protected group is reported but not modified. The coordinator supplies
  that flag while a container lease is active.
  """
  def enforce(cache_group, opts \\ []) do
    with {:ok, snapshot} <- snapshot(cache_group, opts) do
      cond do
        Keyword.get(opts, :protected?, false) ->
          {:ok, %{snapshot: snapshot, evicted: [], bytes_reclaimed: 0, protected?: true}}

        is_nil(CacheSnapshot.limit_bytes(snapshot)) ->
          {:ok, %{snapshot: snapshot, evicted: [], bytes_reclaimed: 0, protected?: false}}

        snapshot.size_bytes <= CacheSnapshot.limit_bytes(snapshot) ->
          {:ok, %{snapshot: snapshot, evicted: [], bytes_reclaimed: 0, protected?: false}}

        true ->
          evict_until_limit(snapshot, opts)
      end
    end
  end

  @doc "Removes all safe top-level payload entries from one group."
  def purge(cache_group, opts \\ []) do
    with {:ok, snapshot} <- snapshot(cache_group, opts) do
      if Keyword.get(opts, :protected?, false) do
        {:ok, %{snapshot: snapshot, removed: [], bytes_reclaimed: 0, protected?: true}}
      else
        {removed, skipped} = remove_entries(snapshot.entries, snapshot.host)
        skipped = snapshot.errors ++ skipped

        with {:ok, final_snapshot} <- snapshot(cache_group, opts) do
          {:ok,
           %{
             snapshot: final_snapshot,
             removed: removed,
             skipped: skipped,
             bytes_reclaimed: Enum.reduce(removed, 0, &(&1.size_bytes + &2)),
             protected?: false
           }}
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshot and eviction internals
  # ---------------------------------------------------------------------------

  defp evict_until_limit(snapshot, opts) do
    candidates =
      snapshot.entries
      |> Enum.filter(& &1.evictable?)
      |> Enum.sort_by(fn entry -> {datetime_score(entry.last_accessed_at), entry.name} end)

    {current, evicted, skipped} =
      Enum.reduce_while(candidates, {snapshot, [], []}, fn entry, {current, evicted, skipped} ->
        if current.size_bytes <= CacheSnapshot.limit_bytes(current) do
          {:halt, {current, evicted, skipped}}
        else
          case remove_entry(entry, current.host) do
            {:ok, _} ->
              case snapshot(
                     %CacheGroup{
                       name: current.group,
                       host: current.host,
                       max_size_mb: current.max_size_mb
                     },
                     opts
                   ) do
                {:ok, refreshed} ->
                  {:cont, {refreshed, [entry | evicted], skipped}}

                {:error, reason} ->
                  {:halt, {current, evicted, [{entry.name, reason} | skipped]}}
              end

            {:error, reason} ->
              {:cont, {current, evicted, [{entry.name, reason} | skipped]}}
          end
        end
      end)

    {:ok,
     %{
       snapshot: current,
       evicted: Enum.reverse(evicted),
       skipped: Enum.reverse(skipped),
       bytes_reclaimed: snapshot.size_bytes - current.size_bytes,
       over_limit?: current.size_bytes > CacheSnapshot.limit_bytes(current),
       protected?: false
     }}
  end

  defp remove_entries(entries, host) do
    Enum.reduce(entries, {[], []}, fn entry, {removed, skipped} ->
      if entry.evictable? do
        case remove_entry(entry, host) do
          {:ok, _} -> {[entry | removed], skipped}
          {:error, reason} -> {removed, [{entry.name, reason} | skipped]}
        end
      else
        {removed, [{entry.name, :protected_mount} | skipped]}
      end
    end)
    |> then(fn {removed, skipped} -> {Enum.reverse(removed), Enum.reverse(skipped)} end)
  end

  defp remove_entry(%{name: name, path: path}, host) do
    cond do
      not contained?(path, host) ->
        {:error, :outside_group}

      path != Path.join(host, name) ->
        {:error, :unexpected_path}

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
          {:ok, _stat} -> File.rm_rf(path)
          {:error, :enoent} -> {:ok, :already_absent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp scan_entries(host, metadata) do
    case File.ls(host) do
      {:ok, names} ->
        Enum.reduce(names, {[], []}, fn name, {entries, errors} ->
          path = Path.join(host, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :symlink}} ->
              {entries, [{name, :symlink} | errors]}

            {:ok, %File.Stat{type: type} = stat} ->
              {size_bytes, size_errors} = tree_size(path, stat)

              previous =
                get_in(metadata, ["entries", name, "last_accessed_at"]) |> parse_datetime()

              last_accessed_at = latest_datetime([previous, stat_datetime(stat)])

              entry = %{
                name: name,
                path: path,
                type: type,
                size_bytes: size_bytes,
                last_accessed_at: last_accessed_at,
                evictable?:
                  type in [:directory, :regular] and
                    not configured_mount_inside?(path)
              }

              {[entry | entries], size_errors ++ errors}

            {:error, reason} ->
              {entries, [{name, reason} | errors]}
          end
        end)
        |> then(fn {entries, errors} ->
          {Enum.sort_by(Enum.reverse(entries), & &1.name), Enum.reverse(errors)}
        end)

      {:error, :enoent} ->
        {[], []}

      {:error, reason} ->
        {[], [{:list, reason}]}
    end
  end

  defp tree_size(_path, %File.Stat{type: :regular} = stat), do: {stat.size, []}
  defp tree_size(_path, %File.Stat{type: type}) when type != :directory, do: {0, []}

  defp tree_size(path, %File.Stat{type: :directory}) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce(names, {0, []}, fn name, {size, errors} ->
          child = Path.join(path, name)

          case File.lstat(child) do
            {:ok, %File.Stat{type: :symlink}} ->
              {size, [{child, :symlink} | errors]}

            {:ok, stat} ->
              {child_size, child_errors} = tree_size(child, stat)
              {size + child_size, child_errors ++ errors}

            {:error, reason} ->
              {size, [{child, reason} | errors]}
          end
        end)

      {:error, reason} ->
        {0, [{path, reason}]}
    end
  end

  defp snapshot_metadata(%CacheSnapshot{} = snapshot, metadata) do
    entries =
      Map.new(snapshot.entries, fn entry ->
        {entry.name,
         %{
           "last_accessed_at" => encode_datetime(entry.last_accessed_at),
           "size_bytes" => entry.size_bytes
         }}
      end)

    metadata
    |> Map.put("version", @metadata_version)
    |> Map.put("group", snapshot.group)
    |> Map.put("size_bytes", snapshot.size_bytes)
    |> Map.put("captured_at", DateTime.to_iso8601(snapshot.captured_at))
    |> Map.put("entries", entries)
  end

  # ---------------------------------------------------------------------------
  # Host path and metadata safety
  # ---------------------------------------------------------------------------

  defp safe_group_path(%CacheGroup{} = group) do
    case CacheGroup.host_path(group) do
      host when is_binary(host) ->
        expanded = expand_path(host)

        cond do
          not absolute?(expanded) ->
            {:error, :cache_path_not_absolute}

          not contained?(expanded, cache_root()) ->
            {:error, :cache_path_outside_root}

          expanded == cache_root() ->
            {:error, :cache_path_is_root}

          true ->
            case reject_symlink_components(expanded) do
              :ok -> {:ok, expanded}
              {:error, reason} -> {:error, {:cache_path, reason}}
            end
        end

      _ ->
        {:error, :invalid_cache_path}
    end
  end

  defp safe_group_path(_), do: {:error, :invalid_cache_path}

  defp metadata_outside_payload(%CacheGroup{} = group, opts) do
    metadata = metadata_root(opts)

    case CacheGroup.host_path(group) do
      host when is_binary(host) ->
        host = expand_path(host)

        if metadata == host or contained?(metadata, host) do
          {:error, :metadata_inside_cache_payload}
        else
          :ok
        end

      _ ->
        {:error, :invalid_cache_path}
    end
  end

  defp configured_mount_inside?(path) do
    path = Path.expand(path)

    Enum.any?(Config.caches(), fn
      %CacheGroup{} = group ->
        configured = group |> CacheGroup.host_path() |> expand_path()
        configured != path and contained?(configured, path)

      _ ->
        false
    end)
  end

  defp read_metadata(name, opts) do
    with {:ok, path} <- metadata_path(name, opts) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, %{}}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :metadata_symlink}

        {:ok, _} ->
          case File.read(path) do
            {:ok, contents} ->
              case Jason.decode(contents) do
                {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
                _ -> {:ok, %{}}
              end

            {:error, reason} ->
              {:error, {:metadata_read, reason}}
          end

        {:error, reason} ->
          {:error, {:metadata_stat, reason}}
      end
    end
  end

  defp write_metadata(name, metadata, opts) do
    with {:ok, path} <- metadata_path(name, opts),
         :ok <- ensure_metadata_root(metadata_root(opts)),
         {:ok, encoded} <- Jason.encode(metadata),
         :ok <- reject_metadata_symlink(path) do
      temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      result =
        with :ok <- File.write(temporary, encoded, [:binary]),
             :ok <- File.chmod(temporary, 0o600),
             :ok <- File.rename(temporary, path) do
          :ok
        end

      if result != :ok, do: _ = File.rm(temporary)
      result
    end
  end

  defp metadata_path(name, opts) when is_binary(name) do
    root = metadata_root(opts)

    cond do
      not Regex.match?(@cache_name, name) ->
        {:error, :invalid_group_name}

      not absolute?(root) ->
        {:error, :metadata_root_not_absolute}

      not contained?(Path.join(root, name <> ".json"), root) ->
        {:error, :metadata_path_outside_root}

      true ->
        case reject_symlink_components(root) do
          :ok -> {:ok, Path.join(root, name <> ".json")}
          {:error, reason} -> {:error, {:metadata_root, reason}}
        end
    end
  end

  defp metadata_path(_, _), do: {:error, :invalid_group_name}

  defp ensure_metadata_root(root) do
    with :ok <- reject_symlink_components(root),
         :ok <- File.mkdir_p(root),
         :ok <- reject_symlink_components(root) do
      :ok
    end
  end

  defp reject_metadata_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :metadata_symlink}
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:metadata_stat, reason}}
    end
  end

  defp reject_symlink_components(path) do
    path
    |> Path.split()
    |> Enum.reduce_while("/", fn component, parent ->
      current = if component == "/", do: "/", else: Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _} -> {:cont, current}
        {:error, :enoent} -> {:cont, current}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      error -> error
    end
  end

  defp contained?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path != root and String.starts_with?(path, root <> "/")
  end

  defp absolute?(path), do: Path.type(path) == :absolute
  defp expand_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_path(path), do: Path.expand(path)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp latest_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, fn value, latest ->
      if is_nil(latest) or DateTime.compare(value, latest) == :gt, do: value, else: latest
    end)
  end

  defp datetime_score(nil), do: 0
  defp datetime_score(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  # Linux commonly mounts developer home directories with relatime, which
  # makes atime identical for unrelated cache entries. mtime is the stable
  # last-observed activity signal for coarse package-manager directories.
  defp stat_datetime(%File.Stat{mtime: mtime}), do: calendar_datetime(mtime)

  defp calendar_datetime({{year, month, day}, {hour, minute, second}}) do
    NaiveDateTime.new!(year, month, day, hour, minute, second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  defp calendar_datetime(%DateTime{} = value), do: value
  defp calendar_datetime(_), do: nil
end
