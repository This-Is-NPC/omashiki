defmodule Omashiki.ConfigFiles do
  @moduledoc """
  Named, versioned copies of the operator's TOML files, edited from the Config
  screen.

  Two kinds share one model. `:config` is the house configuration, the file
  `Omashiki.Config.Rollout` reloads; `:views` is the file
  `OmashikiWeb.TaskViews` reads. Each kind has a *live path*, and the live file
  stays the source of truth: nothing here touches the database, and boot reads
  the live file exactly as it would without this module.

  ## Store

  Documents live next to the live file, in
  `<dirname(live)>/.omashiki-files/<kind>/<name>.toml`, beside an `applied`
  file naming the document the live path is a copy of. The first use of a kind
  imports the existing live file as a document named after its basename.

  Only apply and saving the applied document write the live path, so any other
  difference between the two is an edit made outside Omashiki. `list/1`
  reports it as drift, and the next read adopts the disk content as the applied
  document, keeping the store's copy as a version.

  ## Pieces

  The `include` pieces of the applied configuration are documents too, named
  by their include-relative path. They have history but no drafts: a piece is
  only ever the file the house loads.

  ## Read-only directories

  Writes replace files by rename, so they need a directory that accepts new
  files: the live file's own and the store's. When one refuses, every write
  returns `{:error, {:read_only, dir}}`, and `list/1` and `read/2` still show
  what can be read, the live file standing in for the applied document.

  ## Writes

  Every write is atomic (a temporary file in the same directory, then a
  rename), is checked against the hash the editor opened, and keeps the content
  it replaced as a version, the last 50 per document. Applying records the
  live content it replaced in the applied document's history, so restoring that
  version undoes the apply. Drafts may be saved while invalid; the applied
  document and pieces are validated before anything is written.
  """

  require Logger

  alias Omashiki.Accounts.User
  alias Omashiki.Config
  alias Omashiki.Config.{Include, Registry, Rollout}
  alias OmashikiWeb.TaskViews

  @kinds [:config, :views]
  @name ~r/^[a-z0-9][a-z0-9_-]{0,39}$/
  @version_id ~r/^[0-9]{1,20}$/
  @store ".omashiki-files"
  @history_cap 50

  @doc """
  Every document of `kind`, which one is applied, whether the live file
  drifted, and `read_only`, the directory that refuses writes, or nil.
  """
  def list(kind) when kind in @kinds do
    locked(kind, fn ->
      read_only =
        case prepare(kind) do
          :ok -> nil
          {:error, {:read_only, dir}} -> dir
          {:error, _reason} -> root(kind)
        end

      applied = live_name(kind)
      names = (List.wrap(applied) ++ document_names(kind)) |> Enum.uniq() |> Enum.sort()

      documents =
        for(name <- names, do: document(kind, name, applied)) ++
          for {rel, path} <- piece_paths(kind), do: piece(rel, path)

      %{
        applied: applied,
        drift?: drift(kind) != :none,
        documents: documents,
        read_only: read_only
      }
    end)
  end

  @doc """
  Content and hash of a document or piece. Adopts an outside edit of the live
  file first; when the store cannot be written, the applied document reads as
  the live file.
  """
  def read(kind, name) when kind in @kinds do
    locked(kind, fn ->
      located =
        case with(:ok <- prepare(kind), do: adopt_drift(kind)) do
          :ok ->
            locate(kind, name)

          _error ->
            if name == live_name(kind), do: {:document, live_path(kind)}, else: locate(kind, name)
        end

      with {_type, path} <- located,
           {:ok, content} <- File.read(path) do
        {:ok, %{content: content, hash: hash(content)}}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Validate `content` without writing it. A configuration is checked as if it
  were the live file; content for a piece is checked inside the applied root.
  """
  def validate(kind, content, name \\ nil)

  def validate(:config, content, name) when is_binary(content) do
    live = live_path(:config)

    case locate(:config, name) do
      {:piece, path} -> Config.check(File.read!(live), live, pieces: %{path => content})
      _ -> Config.check(content, live)
    end
  end

  def validate(:views, content, _name) when is_binary(content) do
    case TaskViews.parse(content) do
      {:ok, _views, _default_view} -> {:ok, %{}}
      {:error, errors} -> {:error, Enum.join(errors, "\n")}
    end
  end

  @doc "Create a draft, empty (`from: :blank`) or copied from another document or piece."
  def create(kind, name, opts) when kind in @kinds do
    author = author!(opts)

    locked(kind, fn ->
      with :ok <- prepare(kind),
           :ok <- valid_name(name),
           path = doc_path(kind, name),
           false <- File.exists?(path) && {:error, :exists},
           {:ok, content} <- initial_content(kind, Keyword.fetch!(opts, :from)),
           :ok <- commit(kind, {:document, name}, path, content, author) do
        {:ok, document(kind, name, applied_name(kind))}
      end
    end)
  end

  @doc """
  Save a document. Drafts land in the store as they are; the applied document
  and pieces are validated, written live and reloaded. `reload` is the
  reload's result, nil when nothing was reloaded.
  """
  def save(kind, name, content, expected_hash, opts) when kind in @kinds and is_binary(content) do
    author = author!(opts)

    locked(kind, fn ->
      with :ok <- prepare(kind) do
        case locate(kind, name) do
          {:document, path} ->
            if name == applied_name(kind),
              do: save_applied(kind, name, path, content, expected_hash, author),
              else: save_draft(kind, name, path, content, expected_hash, author)

          {:piece, path} ->
            save_piece(kind, name, path, content, expected_hash, author)

          :error ->
            {:error, :not_found}
        end
      end
    end)
  end

  @doc "Validate a document, make it the live file, and reload the house for `:config`."
  def apply(kind, name, opts) when kind in @kinds do
    author = author!(opts)

    locked(kind, fn ->
      with :ok <- prepare(kind),
           :ok <- adopt_drift(kind) do
        case locate(kind, name) do
          {:document, path} ->
            content = File.read!(path)

            with :ok <- valid(kind, content, nil),
                 :ok <- commit(kind, {:document, name}, live_path(kind), content, author),
                 :ok <- write_file(kind, applied_path(kind), name) do
              {:ok, %{document: document(kind, name, name), reload: activate(kind)}}
            end

          {:piece, _path} ->
            {:error, :piece}

          :error ->
            {:error, :not_found}
        end
      end
    end)
  end

  @doc "Delete a draft and its history. The applied document and pieces stay."
  def delete(kind, name, opts) when kind in @kinds do
    author = author!(opts)

    locked(kind, fn ->
      with :ok <- prepare(kind) do
        case locate(kind, name) do
          {:document, path} ->
            if name == applied_name(kind) do
              {:error, :applied}
            else
              File.rm!(path)
              File.rm_rf!(history_dir(kind, {:document, name}))
              Logger.info("[ConfigFiles] #{kind} #{name} deleted by #{author}")
              :ok
            end

          {:piece, _path} ->
            {:error, :piece}

          :error ->
            {:error, :not_found}
        end
      end
    end)
  end

  @doc "Versions of a document, newest first. `author` is nil for an edit made outside Omashiki."
  def history(kind, name) when kind in @kinds do
    case history_id(kind, name) do
      nil ->
        []

      id ->
        dir = history_dir(kind, id)

        for version_id <- version_ids(dir) do
          version = dir |> Path.join(version_id <> ".json") |> File.read!() |> Jason.decode!()
          {:ok, at, _offset} = DateTime.from_iso8601(version["at"])
          %{id: version_id, at: at, author: version["author"], hash: version["hash"]}
        end
    end
  end

  @doc "Save a version's content back over the document, as `save/5` does."
  def restore(kind, name, version_id, expected_hash, opts) when kind in @kinds do
    with id when id != nil <- history_id(kind, name),
         true <- is_binary(version_id) and version_id =~ @version_id,
         {:ok, json} <- File.read(Path.join(history_dir(kind, id), version_id <> ".json")) do
      save(kind, name, Jason.decode!(json)["content"], expected_hash, opts)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Lines of `name` that a validation `message` points at. A TOML decode error
  names the file and line it stopped at; a line in another file of the
  configuration, such as a piece checked with the root, is not one of these.
  """
  def error_lines(:config, name, message) when is_binary(message) do
    file =
      case locate(:config, name) do
        {:piece, path} -> path
        _document -> live_path(:config)
      end

    lines(message, Regex.escape(file) <> " ")
  end

  # Views are one file, decoded without a name.
  def error_lines(:views, _name, message) when is_binary(message), do: lines(message, "")

  defp lines(message, file_pattern) do
    for [_match, line] <- Regex.scan(~r/#{file_pattern}on line (\d+):/, message),
        do: String.to_integer(line)
  end

  # -- saving ------------------------------------------------------------------

  defp save_draft(kind, name, path, content, expected_hash, author) do
    with :ok <- unchanged(path, expected_hash, :changed),
         :ok <- commit(kind, {:document, name}, path, content, author) do
      {:ok, %{document: document(kind, name, applied_name(kind)), reload: nil}}
    end
  end

  # The editor opened the live file, so that is what must still be there. A
  # live file that is gone falls back to the store copy the editor was given.
  defp save_applied(kind, name, path, content, expected_hash, author) do
    live = live_path(kind)
    opened = if File.exists?(live), do: live, else: path

    with :ok <- unchanged(opened, expected_hash, :changed_on_disk),
         :ok <- valid(kind, content, nil),
         :ok <- commit(kind, {:document, name}, path, content, author),
         :ok <- write_file(kind, live, content) do
      {:ok, %{document: document(kind, name, name), reload: activate(kind)}}
    end
  end

  defp save_piece(kind, rel, path, content, expected_hash, author) do
    with :ok <- unchanged(path, expected_hash, :changed_on_disk),
         :ok <- valid(kind, content, rel),
         :ok <- commit(kind, {:piece, rel}, path, content, author) do
      {:ok, %{document: piece(rel, path), reload: activate(kind)}}
    end
  end

  defp unchanged(path, expected_hash, error) do
    if hash_file(path) == expected_hash, do: :ok, else: {:error, error}
  end

  defp valid(kind, content, name) do
    case validate(kind, content, name) do
      {:ok, _summary} -> :ok
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  defp activate(:config), do: Rollout.reload()
  defp activate(:views), do: nil

  defp initial_content(_kind, :blank), do: {:ok, ""}

  defp initial_content(kind, from) do
    with {_type, path} <- locate(kind, from),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> {:error, :not_found}
    end
  end

  defp valid_name(name) when is_binary(name) do
    if name =~ @name, do: :ok, else: {:error, :invalid_name}
  end

  defp valid_name(_name), do: {:error, :invalid_name}

  defp author!(opts) do
    %User{username: username} = Keyword.fetch!(opts, :author)
    username
  end

  # -- store -------------------------------------------------------------------

  defp live_path(:config), do: Config.default_path()
  defp live_path(:views), do: TaskViews.path()

  defp root(kind), do: Path.dirname(live_path(kind))
  defp store_dir(kind), do: Path.join([root(kind), @store, Atom.to_string(kind)])
  defp doc_path(kind, name), do: Path.join(store_dir(kind), "#{name}.toml")
  defp applied_path(kind), do: Path.join(store_dir(kind), "applied")

  defp history_dir(kind, {:document, name}),
    do: Path.join([store_dir(kind), "history", "documents", name])

  defp history_dir(kind, {:piece, rel}),
    do: Path.join([store_dir(kind), "history", "pieces", rel])

  defp document_names(kind) do
    case File.ls(store_dir(kind)) do
      {:ok, files} ->
        for file <- Enum.sort(files),
            name = Path.basename(file, ".toml"),
            file == name <> ".toml" and name =~ @name,
            do: name

      {:error, _reason} ->
        []
    end
  end

  defp applied_name(kind) do
    with {:ok, name} <- File.read(applied_path(kind)),
         true <- name =~ @name and File.regular?(doc_path(kind, name)) do
      name
    else
      _ -> nil
    end
  end

  # The pieces of the live root, `{include-relative path, absolute path}`. A
  # root whose includes do not resolve has no editable pieces.
  defp piece_paths(:config) do
    live = live_path(:config)

    with {:ok, content} <- File.read(live),
         {:ok, map} <- Toml.decode(content) do
      for path <- Include.pieces!(map, live), do: {Path.relative_to(path, root(:config)), path}
    else
      _ -> []
    end
  rescue
    Config.Error -> []
  end

  defp piece_paths(:views), do: []

  defp locate(kind, name) when is_binary(name) do
    piece = List.keyfind(piece_paths(kind), name, 0)

    cond do
      name =~ @name and File.regular?(doc_path(kind, name)) -> {:document, doc_path(kind, name)}
      piece -> {:piece, elem(piece, 1)}
      true -> :error
    end
  end

  defp locate(_kind, _name), do: :error

  defp history_id(kind, name) do
    case locate(kind, name) do
      {type, _path} -> {type, name}
      :error -> nil
    end
  end

  defp document(kind, name, applied) do
    path = if name == applied, do: live_path(kind), else: doc_path(kind, name)

    %{
      name: name,
      applied?: name == applied,
      piece?: false,
      path: path,
      hash: hash_file(doc_path(kind, name)),
      updated_at: mtime(path)
    }
  end

  defp piece(rel, path) do
    %{
      name: rel,
      applied?: false,
      piece?: true,
      path: path,
      hash: hash_file(path),
      updated_at: mtime(path)
    }
  end

  # Ready for writes: every directory a write renames into accepts new files,
  # and the live file has been imported.
  defp prepare(kind) do
    with :ok <- writable(kind), do: bootstrap(kind)
  end

  # A directory that does not exist yet is created inside its nearest existing
  # ancestor, which has to accept it instead.
  defp writable(kind) do
    [root(kind), store_dir(kind)]
    |> Enum.map(&existing_dir/1)
    |> Enum.uniq()
    |> Enum.find(&(not accepts_files?(&1)))
    |> case do
      nil -> :ok
      dir -> {:error, {:read_only, dir}}
    end
  end

  defp existing_dir(path) do
    parent = Path.dirname(path)
    if File.dir?(path) or parent == path, do: path, else: existing_dir(parent)
  end

  # Asks the file system rather than reading mode bits, which say nothing
  # about a read-only mount.
  defp accepts_files?(dir) do
    probe = Path.join(dir, ".omashiki-probe.#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok -> File.rm(probe) == :ok
      {:error, _reason} -> false
    end
  end

  # First use of a kind: the live file becomes the applied document.
  defp bootstrap(kind) do
    live = live_path(kind)

    if is_nil(applied_name(kind)) and File.regular?(live) do
      name = import_name(live)

      with {:ok, content} <- File.read(live),
           :ok <- commit(kind, {:document, name}, doc_path(kind, name), content, nil) do
        write_file(kind, applied_path(kind), name)
      end
    else
      :ok
    end
  end

  # The applied document, or the name the live file would be imported under
  # when the store has not imported it.
  defp live_name(kind) do
    live = live_path(kind)

    cond do
      name = applied_name(kind) -> name
      File.regular?(live) -> import_name(live)
      true -> nil
    end
  end

  defp import_name(live) do
    name =
      live
      |> Path.basename(".toml")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.slice(0, 40)

    if name =~ @name, do: name, else: "main"
  end

  defp drift(kind) do
    with name when is_binary(name) <- applied_name(kind),
         {:ok, content} <- File.read(live_path(kind)),
         false <- hash(content) == hash_file(doc_path(kind, name)) do
      {:drift, name, content}
    else
      _ -> :none
    end
  end

  defp adopt_drift(kind) do
    case drift(kind) do
      {:drift, name, content} ->
        commit(kind, {:document, name}, doc_path(kind, name), content, nil)

      :none ->
        :ok
    end
  end

  # -- writes ------------------------------------------------------------------

  # Writes `content` at `path` and keeps what it replaced in `id`'s history.
  defp commit(kind, id, path, content, author) do
    previous =
      case File.read(path) do
        {:ok, previous} -> previous
        {:error, _reason} -> nil
      end

    with :ok <- write_file(kind, path, content),
         :ok <- record_version(kind, id, previous, content, author) do
      Logger.info(
        "[ConfigFiles] #{kind} #{elem(id, 1)} written by #{author || "an outside edit"} " <>
          "(#{hash(content)})"
      )
    end
  end

  defp record_version(_kind, _id, nil, _content, _author), do: :ok

  defp record_version(kind, id, previous, content, author) do
    if previous == content do
      :ok
    else
      dir = history_dir(kind, id)

      version =
        Jason.encode!(%{
          at: DateTime.to_iso8601(DateTime.utc_now()),
          author: author,
          hash: hash(previous),
          content: previous
        })

      with :ok <- write_file(kind, Path.join(dir, next_version_id(dir) <> ".json"), version) do
        for version_id <- Enum.drop(version_ids(dir), @history_cap),
            do: File.rm!(Path.join(dir, version_id <> ".json"))

        :ok
      end
    end
  end

  # Microseconds since the epoch, bumped past any id already taken, so ids
  # sort by the order they were written.
  defp next_version_id(dir) do
    System.os_time(:microsecond)
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&Integer.to_string/1)
    |> Enum.find(&(not File.exists?(Path.join(dir, &1 <> ".json"))))
  end

  defp version_ids(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        for(file <- files, id = Path.basename(file, ".json"), id =~ @version_id, do: id)
        |> Enum.sort_by(&String.to_integer/1, :desc)

      {:error, _reason} ->
        []
    end
  end

  defp write_file(kind, path, content) do
    root = root(kind)
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    with true <- Registry.contained?(path, root) || {:error, :unsafe_path},
         false <- Registry.symlink_in_path?(path, root) && {:error, :unsafe_path},
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp locked(kind, fun), do: :global.trans({{__MODULE__, kind}, self()}, fun)

  defp hash(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp hash_file(path) do
    case File.read(path) do
      {:ok, content} -> hash(content)
      {:error, _reason} -> nil
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _reason} -> nil
    end
  end
end
