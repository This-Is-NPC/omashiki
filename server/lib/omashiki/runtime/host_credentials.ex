defmodule Omashiki.Runtime.HostCredentials do
  @moduledoc """
  Materializes declared host credential origins for exactly one attempt.

  Each attempt gets a private `0700` directory holding `0600` copies of the
  live operator credentials, mounted read-write at `/run/omashiki/state`. The
  copy is per attempt because OAuth harnesses rewrite these files on token
  refresh and concurrent containers would corrupt a shared origin.
  """

  alias Omashiki.Config.HostCredential

  @container_dir HostCredential.container_dir()
  @empty %{dir: nil, binds: [], mounts: []}
  @scope ~r/^[A-Za-z0-9._-]+$/

  @doc "Host root holding every per-attempt credential directory."
  def root do
    Application.get_env(:omashiki, :host_credential_root) ||
      Path.join(default_base(), "omashiki-credentials")
  end

  @doc "Private host directory for one attempt scope."
  def scope_dir(scope_id) when is_binary(scope_id) do
    unless Regex.match?(@scope, scope_id) do
      raise ArgumentError, "unsafe attempt scope #{inspect(scope_id)}"
    end

    Path.join(root(), scope_id)
  end

  @doc """
  Copy every origin declared by the environment into the attempt directory.

  Returns the directory bind plus one mount definition per file so harness
  adapters resolve their credential paths. A missing origin fails the attempt.
  """
  def materialize(scope_id, environment, opts \\ []) when is_binary(scope_id) do
    case declared(environment) do
      [] -> {:ok, @empty}
      credentials -> copy_all(scope_id, credentials, Keyword.get(opts, :owner))
    end
  end

  @doc "Remove one attempt's credential directory. Idempotent."
  def discard(scope_id) when is_binary(scope_id) do
    _ = File.rm_rf(scope_dir(scope_id))
    :ok
  rescue
    ArgumentError -> :ok
  end

  def discard(_scope_id), do: :ok

  @doc "Drop credential directories that no longer belong to an active attempt."
  def sweep(active_scope_ids) when is_list(active_scope_ids) do
    active = MapSet.new(active_scope_ids)

    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&MapSet.member?(active, &1))
        |> Enum.each(&discard/1)

      _ ->
        :ok
    end

    :ok
  end

  defp copy_all(scope_id, credentials, owner) do
    dir = scope_dir(scope_id)

    with :ok <- reset(dir),
         {:ok, mounts} <- copy_files(dir, credentials, owner) do
      chown(dir, owner)
      {:ok, %{dir: dir, binds: ["#{dir}:#{@container_dir}"], mounts: mounts}}
    else
      {:error, reason} ->
        discard(scope_id)
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

  defp copy_file(dir, name, file, origin, mounts, owner) do
    target = Path.join(@container_dir, file)

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

  defp expand_host_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_host_path("~"), do: System.user_home!()
  defp expand_host_path(path), do: path

  defp default_base, do: if(File.dir?("/dev/shm"), do: "/dev/shm", else: System.tmp_dir!())
end
