defmodule Omashiki.Runtime.HostCredentials do
  @moduledoc """
  Materializes declared host credential origins for exactly one attempt.

  Each attempt gets a private `0700` directory holding `0600` copies of the
  live operator credentials, mounted read-write at `/run/omashiki/state`. The
  copy is per attempt because OAuth harnesses rewrite these files on token
  refresh and concurrent containers would corrupt a shared origin.

  A `~/` origin is expanded **here**, against the home of the process doing
  the copy. That is the point: the subscription login belongs to the machine
  running Docker (embedded manager or remote worker), not to whoever loaded
  `omashiki.toml`. A worker whose home lacks the file fails the attempt with
  `host_credential_unavailable`; nothing is fetched from anywhere else.

  A copy belongs to the house of its attempt, the one whose id labels the
  attempt's container (`Omashiki.House`). Its directory names both, so houses
  that share a machine each sweep only their own copies.
  """

  alias Omashiki.Config.HostCredential

  @container_dir HostCredential.container_dir()
  @empty %{dir: nil, binds: [], mounts: []}
  @id ~r/^[A-Za-z0-9._-]+$/
  @prefix "omashiki-credentials-"

  @doc """
  Host root holding every per-attempt credential directory. The directories
  sit in it side by side, with no shared parent of their own, so each belongs
  to the user whose house created it and no other user's house can block it.
  """
  def root do
    Application.get_env(:omashiki, :host_credential_root) || default_base()
  end

  @doc """
  Private host directory for one attempt scope of one house,
  `omashiki-credentials-<scope>@<house>`. Neither id may contain `@`, so a
  name splits back into exactly one scope and one house.
  """
  def scope_dir(house, scope_id) when is_binary(house) and is_binary(scope_id) do
    Path.join(root(), @prefix <> safe_id!(scope_id) <> "@" <> safe_id!(house))
  end

  defp safe_id!(id) do
    if Regex.match?(@id, id), do: id, else: raise(ArgumentError, "unsafe id #{inspect(id)}")
  end

  @doc """
  Copy every origin declared by the environment into the directory of the
  attempt scope of `house`.

  Returns the directory bind plus one mount definition per file so harness
  adapters resolve their credential paths. A missing origin fails the attempt.
  """
  def materialize(house, scope_id, environment, opts \\ [])
      when is_binary(house) and is_binary(scope_id) do
    case declared(environment) do
      [] -> {:ok, @empty}
      credentials -> copy_all(scope_dir(house, scope_id), credentials, Keyword.get(opts, :owner))
    end
  end

  @doc "Remove one attempt's credential directory. Idempotent."
  def discard(house, scope_id) when is_binary(house) and is_binary(scope_id) do
    _ = File.rm_rf(scope_dir(house, scope_id))
    :ok
  rescue
    ArgumentError -> :ok
  end

  def discard(_house, _scope_id), do: :ok

  @doc """
  Drop the credential directories of `houses` that no longer belong to an
  active attempt. Those of every other house stay.
  """
  def sweep(houses, active_scope_ids) when is_list(houses) and is_list(active_scope_ids) do
    active = MapSet.new(active_scope_ids)

    case File.ls(root()) do
      {:ok, entries} ->
        for @prefix <> name <- entries,
            [scope_id, house] <- [String.split(name, "@")],
            house in houses,
            not MapSet.member?(active, scope_id),
            do: discard(house, scope_id)

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Whether a declared origin can be copied on this machine, as an attempt would
  copy it. `:ok`, or `{:error, reason}` when it is not a readable file.
  """
  def readable(declared) when is_binary(declared) do
    origin = expand_host_path(declared)

    if File.regular?(origin) do
      with {:ok, file} <- File.open(origin, [:read]), do: File.close(file)
    else
      {:error, :enoent}
    end
  end

  defp copy_all(dir, credentials, owner) do
    with :ok <- reset(dir),
         {:ok, mounts} <- copy_files(dir, credentials, owner) do
      chown(dir, owner)
      {:ok, %{dir: dir, binds: ["#{dir}:#{@container_dir}"], mounts: mounts}}
    else
      {:error, reason} ->
        _ = File.rm_rf(dir)
        {:error, reason}
    end
  end

  defp reset(dir) do
    _ = File.rm_rf(dir)

    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp copy_files(dir, credentials, owner) do
    Enum.reduce_while(credentials, {:ok, []}, fn credential, {:ok, mounts} ->
      credential.files
      |> Enum.sort()
      |> Enum.reduce_while({:ok, mounts}, fn {file, origin}, {:ok, acc} ->
        case copy_file(dir, credential.name, file, origin, acc, owner) do
          {:ok, mount} -> {:cont, {:ok, [mount | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mounts} -> {:ok, Enum.reverse(mounts)}
      error -> error
    end
  end

  defp copy_file(dir, name, file, declared, mounts, owner) do
    target = Path.join(@container_dir, file)
    origin = expand_host_path(declared)

    cond do
      Enum.any?(mounts, fn {_source, destination, _read_only} -> destination == target end) ->
        {:error, {:host_credential_conflict, file}}

      not File.regular?(origin) ->
        {:error, {:host_credential_unavailable, name, file}}

      true ->
        destination = Path.join(dir, file)
        write(destination, origin)
        chown(destination, owner)
        {:ok, {destination, target, false}}
    end
  rescue
    _ -> {:error, {:host_credential_copy_failed, name, file}}
  end

  defp write(destination, origin) do
    File.open!(destination, [:write, :binary, :exclusive], fn file ->
      File.chmod!(destination, 0o600)
      IO.binwrite(file, File.read!(origin))
    end)
  end

  # Best-effort, exactly like the harness secret files: the orchestrator is
  # normally already the owning UID and may lack CAP_CHOWN.
  defp chown(_path, nil), do: :ok

  defp chown(path, {uid, gid}) do
    _ = System.cmd("chown", ["#{uid}:#{gid}", path], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp declared(environment) when is_map(environment) do
    environment
    |> Map.get(:host_credentials, Map.get(environment, "host_credentials", []))
    |> List.wrap()
    |> Enum.map(fn credential ->
      %{
        name: Map.get(credential, :name, Map.get(credential, "name")),
        files: Map.get(credential, :files, Map.get(credential, "files", %{}))
      }
    end)
    |> Enum.reject(&(map_size(&1.files) == 0))
  end

  defp declared(_environment), do: []

  @doc "Validate a writable mount exists for a container credential path."
  def validate_mount(mounts, target) when is_binary(target) do
    case Enum.find(normalize_mounts(mounts), fn
           {_source, destination, _read_only} -> destination == target
           {_source, destination} -> destination == target
           _ -> false
         end) do
      {source, ^target, false} when is_binary(source) ->
        if File.regular?(expand_host_path(source)),
          do: :ok,
          else: {:error, {:credentials_unavailable, source}}

      {source, ^target, _} when is_binary(source) ->
        {:error, {:credentials_mount_must_be_writable, source}}

      nil ->
        {:error, {:credentials_mount_missing, target}}
    end
  end

  defp normalize_mounts(mounts) when is_map(mounts), do: Enum.to_list(mounts)
  defp normalize_mounts(mounts) when is_list(mounts), do: mounts
  defp normalize_mounts(_), do: []

  defp expand_host_path("~/" <> rest), do: Path.join(home(), rest)
  defp expand_host_path("~"), do: home()
  defp expand_host_path(path), do: path

  # `HOME` first: the release entrypoint and Compose set it per process, and
  # `System.user_home!/0` is frozen at VM boot from wherever the BEAM started.
  defp home do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" -> home
      _ -> System.user_home!()
    end
  end

  defp default_base, do: if(File.dir?("/dev/shm"), do: "/dev/shm", else: System.tmp_dir!())
end
