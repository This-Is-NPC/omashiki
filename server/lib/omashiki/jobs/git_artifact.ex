defmodule Omashiki.Jobs.GitArtifact do
  @moduledoc "Creates, validates, finalizes, and retires one job Git artifact."

  alias Omashiki.Jobs.Job

  @max_bytes 100 * 1024 * 1024
  @retention_seconds 30 * 24 * 60 * 60
  @branch_prefix "omashiki/job-"

  @type artifact :: %{
          repo_path: String.t(),
          path: String.t(),
          branch: String.t(),
          base_sha: String.t(),
          job_id: String.t()
        }

  @doc "Create the isolated job worktree from the captured base branch SHA."
  def provision_worktree(job, opts \\ [])

  def provision_worktree(%Job{id: job_id, repository_snapshot: snapshot}, opts) do
    with :ok <- valid_job_id(job_id),
         {:ok, repo_path} <- snapshot_string(snapshot, "path"),
         {:ok, base_branch} <- snapshot_string(snapshot, "base_branch"),
         :ok <- validate_repo(repo_path),
         :ok <- not_cancelled(opts),
         {:ok, base_sha} <-
           git(repo_path, ["rev-parse", "--verify", "#{base_branch}^{commit}"], opts),
         artifact <- artifact(repo_path, job_id, base_sha),
         :ok <- collision_check(artifact, opts),
         :ok <- File.mkdir_p(Path.dirname(artifact.path)) do
      case git(
             repo_path,
             ["worktree", "add", "--quiet", "-b", artifact.branch, artifact.path, base_sha],
             opts
           ) do
        {:ok, _} ->
          {:ok, artifact}

        {:error, {:git_failed, status, output}} ->
          _ = cleanup(artifact, preserve_branch: false, git_env: Keyword.get(opts, :git_env, []))
          {:error, {:provision_failed, status, output}}

        {:error, reason} ->
          _ = cleanup(artifact, preserve_branch: false, git_env: Keyword.get(opts, :git_env, []))
          {:error, reason}
      end
    else
      {:error, {:git_failed, status, output}} -> {:error, {:provision_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  def provision_worktree(_, _), do: {:error, :invalid_job_snapshot}

  @doc "Provision a worktree, invoke the container callback, and clean up failures."
  def provision(%Job{} = job, opts, callback) when is_function(callback, 1) do
    with {:ok, artifact} <- provision_worktree(job, opts) do
      case safe_callback(callback, artifact) do
        {:ok, result} ->
          {:ok, Map.put(result, :artifact, artifact)}

        {:error, reason} ->
          _ = cleanup(artifact, preserve_branch: false, git_env: Keyword.get(opts, :git_env, []))
          {:error, reason}
      end
    end
  end

  @doc "Finalize an artifact, committing safe dirty output and returning Git metadata."
  def finalize(%{} = artifact, %Job{} = job, opts \\ []) do
    with :ok <- not_cancelled(opts),
         {:ok, paths} <- dirty_paths(artifact.path, opts),
         {:ok, changed_bytes} <- changed_bytes(artifact.path, paths),
         :ok <- safety_scan(artifact.path, paths, changed_bytes, opts),
         {:ok, previous_head} <- commit_if_dirty(artifact, job, paths, changed_bytes, opts),
         {:ok, head_sha} <- git(artifact.path, ["rev-parse", "HEAD"], opts),
         :ok <- verify_head(artifact, head_sha, previous_head, opts) do
      {:ok,
       %{
         branch: artifact.branch,
         base_sha: artifact.base_sha,
         head_sha: head_sha,
         worktree_clean: true,
         result: %{
           "job_id" => to_string(job.id),
           "base_sha" => artifact.base_sha,
           "head_sha" => head_sha,
           "changed_bytes" => changed_bytes
         }
       }}
    end
  end

  @doc "Remove a job worktree and optionally its branch."
  def cleanup(%{} = artifact, opts \\ []) do
    worktree_result = cleanup_worktree(artifact, opts)

    branch_result =
      if Keyword.get(opts, :preserve_branch, false) do
        :ok
      else
        delete_branch(artifact.repo_path, artifact.branch, opts)
      end

    case {worktree_result, branch_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _} -> {:error, reason}
      {_, {:error, reason}} -> {:error, reason}
    end
  end

  @doc "Delete successful job branches whose tip is older than the retention period."
  def prune_expired(repo_path, opts \\ []) when is_binary(repo_path) do
    cutoff = Keyword.get(opts, :cutoff, System.system_time(:second) - @retention_seconds)

    with :ok <- validate_repo(repo_path),
         {:ok, refs} <-
           git(
             repo_path,
             [
               "for-each-ref",
               "--format=%(refname:short)\t%(committerdate:unix)",
               "refs/heads/#{@branch_prefix}*"
             ],
             opts
           ) do
      refs
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, pruned} ->
        case String.split(line, "\t", parts: 2) do
          [branch, timestamp] when branch != "" ->
            if parse_integer(timestamp) < cutoff do
              case delete_branch(repo_path, branch, opts) do
                :ok -> {:cont, {:ok, [branch | pruned]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            else
              {:cont, {:ok, pruned}}
            end

          _ ->
            {:cont, {:ok, pruned}}
        end
      end)
      |> case do
        {:ok, branches} -> {:ok, Enum.reverse(branches)}
        error -> error
      end
    end
  end

  @doc "Return the configured automatic-commit bound."
  def max_bytes, do: @max_bytes

  @doc "Return the branch prefix used for successful job artifacts."
  def branch_prefix, do: @branch_prefix

  defp artifact(repo_path, job_id, base_sha) do
    branch = @branch_prefix <> to_string(job_id)

    %{
      repo_path: repo_path,
      path: Path.join(repo_path, Path.join(".omashiki-worktrees", "job-#{job_id}")),
      branch: branch,
      base_sha: base_sha,
      job_id: to_string(job_id)
    }
  end

  defp collision_check(%{repo_path: repo_path, path: path, branch: branch}, opts) do
    cond do
      File.exists?(path) -> {:error, {:collision, :worktree, path}}
      ref_exists?(repo_path, branch, opts) -> {:error, {:collision, :branch, branch}}
      true -> :ok
    end
  end

  defp commit_if_dirty(_artifact, _job, [], _changed_bytes, _opts), do: {:ok, nil}

  defp commit_if_dirty(artifact, job, _paths, changed_bytes, opts) do
    with :ok <- not_cancelled(opts),
         {:ok, previous_head} <- git(artifact.path, ["rev-parse", "HEAD"], opts),
         {:ok, _} <- git(artifact.path, ["add", "--all", "--", "."], opts),
         {:ok, _} <-
           git(
             artifact.path,
             [
               "-c",
               "user.name=Omashiki",
               "-c",
               "user.email=jobs@omashiki.local",
               "commit",
               "-m",
               "chore(omashiki): finalize job #{short_id(job.id)}",
               "-m",
               metadata_message(artifact, job, changed_bytes)
             ],
             opts
           ) do
      {:ok, previous_head}
    else
      {:error, {:git_failed, status, output}} -> {:error, {:commit_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp metadata_message(artifact, job, changed_bytes) do
    "job_id: #{job.id}\nattempt: #{Map.get(job, :current_attempt, 1)}\nbase_sha: #{artifact.base_sha}\nchanged_bytes: #{changed_bytes}"
  end

  defp verify_head(artifact, head_sha, previous_head, opts) do
    result =
      with {:ok, branch} <- git(artifact.path, ["symbolic-ref", "--short", "HEAD"], opts),
           true <- branch == artifact.branch,
           {:ok, branch_sha} <-
             git(artifact.repo_path, ["rev-parse", "refs/heads/#{artifact.branch}"], opts),
           true <- branch_sha == head_sha,
           {:ok, paths} <- dirty_paths(artifact.path, opts),
           true <- paths == [] do
        :ok
      else
        false -> {:error, :artifact_verification_failed}
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok ->
        :ok

      error when is_binary(previous_head) ->
        _ = rollback_auto_commit(artifact, previous_head, opts)
        error

      error ->
        error
    end
  end

  defp rollback_auto_commit(artifact, previous_head, opts) do
    case git(artifact.path, ["reset", "--mixed", previous_head], opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:rollback_failed, reason}}
    end
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

  defp dirty_paths(path, opts) do
    case git(path, ["status", "--porcelain=v1", "--untracked-files=all"], opts) do
      {:ok, output} ->
        paths =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&status_path/1)
          |> Enum.reject(&is_nil/1)

        {:ok, paths}

      error ->
        error
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

  defp status_path(<<_x, _y, ?\s, path::binary>>),
    do: path |> String.trim() |> rename_destination()

  defp status_path(_), do: nil

  defp rename_destination(path) do
    path |> String.split(" -> ", parts: 2) |> List.last()
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

  defp cleanup_worktree(%{repo_path: repo_path, path: path}, opts) do
    cond do
      not File.exists?(path) ->
        _ = git(repo_path, ["worktree", "prune"], opts)
        :ok

      true ->
        case git(repo_path, ["worktree", "remove", "--force", path], opts) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:cleanup_failed, reason}}
        end
    end
  end

  defp delete_branch(repo_path, branch, opts) do
    case git(repo_path, ["branch", "-D", branch], opts) do
      {:ok, _} ->
        :ok

      {:error, {:git_failed, _status, output}} ->
        if String.contains?(output, "not found"),
          do: :ok,
          else: {:error, {:branch_cleanup_failed, {:git_failed, output}}}

      {:error, reason} ->
        {:error, {:branch_cleanup_failed, reason}}
    end
  end

  defp validate_repo(path) when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:error, :repository_unavailable}
  end

  defp validate_repo(_), do: {:error, :repository_unavailable}

  defp snapshot_string(snapshot, key) when is_map(snapshot) do
    case Map.get(snapshot, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_snapshot, key}}
    end
  end

  defp snapshot_string(_, key), do: {:error, {:missing_snapshot, key}}

  defp valid_job_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9-]+\z/, id), do: :ok, else: {:error, :invalid_job_id}
  end

  defp valid_job_id(_), do: {:error, :invalid_job_id}

  defp ref_exists?(repo_path, ref, opts) do
    match?({:ok, _}, git(repo_path, ["rev-parse", "--verify", "refs/heads/#{ref}"], opts))
  end

  defp not_cancelled(opts) do
    callback = Keyword.get(opts, :cancelled?, fn -> false end)

    if is_function(callback, 0) and callback.(), do: {:error, :cancelled}, else: :ok
  rescue
    _ -> {:error, :cancelled}
  end

  defp safe_callback(callback, artifact) do
    callback.(artifact)
  rescue
    error -> {:error, {:provision_exception, error}}
  catch
    kind, reason -> {:error, {:provision_throw, kind, reason}}
  end

  defp git(path, args, opts) do
    case System.cmd("git", ["-C", path | args],
           env: Keyword.get(opts, :git_env, []),
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, status, summary(output)}}
    end
  rescue
    error -> {:error, {:git_exception, inspect(error)}}
  end

  defp summary(output), do: output |> to_string() |> String.trim() |> String.slice(0, 4_096)
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)
  defp parse_integer(value), do: String.to_integer(value)

  defp contained?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
