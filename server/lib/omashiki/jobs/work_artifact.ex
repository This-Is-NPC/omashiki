defmodule Omashiki.Jobs.WorkArtifact do
  @moduledoc """
  Ephemeral work directory for `sink=files` and `sink=none` jobs.

  VALIDATE runs before publish, mirroring the Git artifact safety gate without
  touching git.
  """

  alias Omashiki.Jobs.Job

  @max_bytes 100 * 1024 * 1024

  @type artifact :: %{
          required(:path) => String.t(),
          required(:sink) => String.t(),
          required(:job_id) => String.t()
        }

  @doc "Create a tmpdir and invoke the container callback."
  def provision(%Job{id: job_id}, sink, opts, callback) when sink in ["files", "none"] do
    with :ok <- not_cancelled(opts),
         path <- work_path(job_id),
         :ok <- File.mkdir_p(path) do
      artifact = %{path: path, sink: sink, job_id: job_id}

      case safe_callback(callback, artifact) do
        {:ok, result} -> {:ok, Map.put(result, :artifact, artifact)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:provision_failed, inspect(error)}}
  end

  @doc "Validate output and publish by sink."
  def finalize(%{path: path, sink: sink, job_id: job_id}, %Job{} = job, opts \\ []) do
    with :ok <- not_cancelled(opts),
         {:ok, paths} <- output_paths(path),
         {:ok, changed_bytes} <- changed_bytes(path, paths),
         :ok <- safety_scan(path, paths, changed_bytes, opts),
         {:ok, result} <- publish(sink, path, paths, changed_bytes, job_id, job, opts) do
      {:ok, %{result: result}}
    end
  end

  @doc "Remove the ephemeral work directory."
  def cleanup(%{path: path}) do
    if File.exists?(path), do: File.rm_rf!(path)
    :ok
  end

  defp publish("none", _path, _paths, changed_bytes, job_id, _job, _opts) do
    {:ok, %{"job_id" => to_string(job_id), "changed_bytes" => changed_bytes}}
  end

  defp publish("files", path, paths, changed_bytes, job_id, _job, opts) do
    with {:ok, blob_path} <- write_blob(path, paths, job_id, opts),
         {:ok, digest} <- file_digest(blob_path) do
      {:ok,
       %{
         "job_id" => to_string(job_id),
         "changed_bytes" => changed_bytes,
         "blob_path" => blob_path,
         "blob_digest" => digest
       }}
    end
  end

  defp work_path(job_id) do
    Path.join(System.tmp_dir!(), Path.join("omashiki-work", to_string(job_id)))
  end

  defp blob_root(opts) do
    Keyword.get(opts, :blob_root, Path.join(System.tmp_dir!(), "omashiki-blobs"))
  end

  defp write_blob(work_path, paths, job_id, opts) do
    blob_dir = Path.join(blob_root(opts), to_string(job_id))
    File.mkdir_p!(blob_dir)
    blob_path = Path.join(blob_dir, "artifact.tar.gz")

    members =
      Enum.map(paths, fn relative ->
        absolute = Path.join(work_path, relative)
        {String.to_charlist(relative), File.read!(absolute)}
      end)

    case :erl_tar.create(String.to_charlist(blob_path), members, [:compressed]) do
      :ok -> {:ok, blob_path}
      {:error, reason} -> {:error, {:blob_write_failed, reason}}
    end
  end

  defp file_digest(path) do
    digest =
      path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, digest}
  end

  defp output_paths(root) do
    abs_root = Path.expand(root)

    paths =
      abs_root
      |> list_files()
      |> Enum.map(&Path.relative_to(&1, abs_root))
      |> Enum.sort()

    {:ok, paths}
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> list_files(path)
            {:ok, %File.Stat{type: :regular}} -> [path]
            {:ok, %File.Stat{type: :symlink}} -> [path]
            _ -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp changed_bytes(_path, []), do: {:ok, 0}

  defp changed_bytes(path, paths) do
    bytes =
      Enum.reduce(paths, 0, fn relative, total ->
        absolute = Path.expand(Path.join(path, relative))

        if contained?(absolute, Path.expand(path)) do
          case File.lstat(absolute) do
            {:ok, %File.Stat{type: :regular, size: size}} -> total + size
            {:ok, %File.Stat{type: :symlink, size: size}} -> total + size
            _ -> total
          end
        else
          total + @max_bytes + 1
        end
      end)

    {:ok, bytes}
  end

  defp safety_scan(path, paths, changed_bytes, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    protected_paths = Keyword.get(opts, :protected_paths, [])
    protected = Enum.find(paths, &protected_path?(&1, protected_paths))
    symlink = Enum.find(paths, &symlink_path?(path, &1))

    cond do
      symlink ->
        {:error, {:symlink_path, symlink}}

      changed_bytes > max_bytes ->
        {:error, {:oversized_output, changed_bytes, max_bytes}}

      protected ->
        {:error, {:protected_path, protected}}

      Enum.any?(paths, &contains_secret?(path, &1)) ->
        {:error, {:likely_secret, Enum.find(paths, &contains_secret?(path, &1))}}

      true ->
        :ok
    end
  end

  defp protected_path?(path, configured) do
    protected_path?(path) or
      Enum.any?(configured, fn prefix ->
        is_binary(prefix) and
          (path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/"))
      end)
  end

  defp protected_path?(path) do
    normalized = String.downcase(String.trim_leading(path, "./"))
    base = Path.basename(normalized)

    String.starts_with?(normalized, [".git/", ".ssh/", ".aws/"]) or
      base in [".env", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"] or
      String.contains?(base, ["secret", "credential", "password", "token"]) or
      String.ends_with?(base, [".pem", ".key", ".p12", ".pfx"])
  end

  defp contains_secret?(path, relative) do
    absolute = Path.expand(Path.join(path, relative))

    case File.lstat(absolute) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(absolute) do
          {:ok, content} ->
            String.valid?(content) and
              Regex.match?(
                ~r/(?:-----BEGIN .*PRIVATE KEY-----|(?:api[_-]?key|secret|password|token)\s*[:=]\s*\S+|(?:AKIA|ASIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,})/i,
                content
              )

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp symlink_path?(path, relative) do
    case File.lstat(Path.expand(Path.join(path, relative))) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp contained?(path, root), do: String.starts_with?(path, root <> "/") or path == root

  defp not_cancelled(opts) do
    if Keyword.get(opts, :cancelled?, false), do: {:error, :cancelled}, else: :ok
  end

  defp safe_callback(callback, artifact) do
    callback.(artifact)
  rescue
    error -> {:error, {:callback_failed, inspect(error)}}
  catch
    kind, reason -> {:error, {:callback_failed, {kind, reason}}}
  end
end
