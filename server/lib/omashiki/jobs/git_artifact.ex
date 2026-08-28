defmodule Omashiki.Jobs.GitArtifact.MirrorLock do
  @moduledoc false
  use GenServer

  @name __MODULE__

  def with_lock(path, fun) when is_binary(path) and is_function(fun, 0) do
    with {:ok, server} <- server() do
      token = make_ref()

      try do
        case GenServer.call(server, {:acquire, path, self(), token}, :infinity) do
          :ok ->
            try do
              fun.()
            after
              release(server, path, self(), token)
            end

          {:error, reason} ->
            {:error, reason}
        end
      catch
        :exit, reason -> {:error, {:mirror_lock_failed, reason}}
      end
    end
  end

  def start_link(_arg), do: GenServer.start(__MODULE__, %{}, name: @name)

  @impl true
  def init(_state), do: {:ok, %{locks: %{}, queues: %{}}}

  @impl true
  def handle_call({:acquire, path, owner, token}, from, state) do
    case Map.has_key?(state.locks, path) do
      false ->
        {:reply, :ok, acquire_lock(state, path, owner, token, from)}

      true ->
        monitor = Process.monitor(owner)
        queue = Map.get(state.queues, path, :queue.new())
        queue = :queue.in({from, owner, token, monitor}, queue)
        {:noreply, %{state | queues: Map.put(state.queues, path, queue)}}
    end
  end

  @impl true
  def handle_call({:release, path, owner, token}, _from, state) do
    case Map.get(state.locks, path) do
      %{owner: ^owner, token: ^token, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | locks: Map.delete(state.locks, path)}
        {:reply, :ok, grant_next(state, path)}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    case locked_path(state.locks, monitor) do
      {:ok, path} ->
        state = %{state | locks: Map.delete(state.locks, path)}
        {:noreply, grant_next(state, path)}

      :error ->
        {:noreply, remove_queued_monitor(state, monitor)}
    end
  end

  defp server do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case start_link(:ok) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:mirror_lock_failed, reason}}
        end
    end
  end

  defp release(server, path, owner, token) do
    _ = GenServer.call(server, {:release, path, owner, token}, :infinity)
  catch
    :exit, _ -> :ok
  end

  defp acquire_lock(state, path, owner, token, _from) do
    monitor = Process.monitor(owner)
    lock = %{owner: owner, token: token, monitor: monitor}
    %{state | locks: Map.put(state.locks, path, lock)}
  end

  defp grant_next(state, path) do
    case Map.get(state.queues, path) do
      nil ->
        state

      queue ->
        case :queue.out(queue) do
          {:empty, _queue} ->
            %{state | queues: Map.delete(state.queues, path)}

          {{:value, {from, owner, token, monitor}}, queue} ->
            state =
              if Process.alive?(owner) do
                GenServer.reply(from, :ok)
                lock = %{owner: owner, token: token, monitor: monitor}
                %{state | locks: Map.put(state.locks, path, lock)}
              else
                Process.demonitor(monitor, [:flush])
                state
              end

            state =
              if :queue.is_empty(queue),
                do: %{state | queues: Map.delete(state.queues, path)},
                else: %{state | queues: Map.put(state.queues, path, queue)}

            if Map.has_key?(state.locks, path), do: state, else: grant_next(state, path)
        end
    end
  end

  defp locked_path(locks, monitor) do
    case Enum.find(locks, fn {_path, lock} -> lock.monitor == monitor end) do
      {path, _lock} -> {:ok, path}
      nil -> :error
    end
  end

  defp remove_queued_monitor(state, monitor) do
    queues =
      state.queues
      |> Enum.reduce(%{}, fn {path, queue}, acc ->
        queue =
          queue
          |> :queue.to_list()
          |> Enum.reject(fn {_from, _owner, _token, queued_monitor} ->
            queued_monitor == monitor
          end)
          |> :queue.from_list()

        if :queue.is_empty(queue), do: acc, else: Map.put(acc, path, queue)
      end)

    %{state | queues: queues}
  end
end

defmodule Omashiki.Jobs.GitArtifact do
  @moduledoc """
  Creates, validates, finalizes, and retires per-attempt Git run branches.

  Each admitted git job carries a persisted `task_branch` (from `payload.branch`
  or `slug(payload.title)`). Every attempt provisions an immutable run ref
  `task_branch-run-NNN` and a worktree under
  `.omashiki-worktrees/<sanitized-task-branch>-run-NNN`. The task-branch pointer
  advances only on succeeded finalization; failed dirty attempts still publish
  their run branch when finalized.

  ## Publication

  The deliverable is the branch on the repository's canonical remote, not the
  local one: a branch that exists only on the node that ran the attempt is
  unreachable from every other node. `finalize/3` therefore pushes after — never
  before — the safety validations, so unvalidated output cannot reach a remote
  shared by the whole cluster.

  Run branches are create-only (`--force-with-lease=<run-ref>:`). The task-branch
  pointer move may be non-fast-forward and uses `--force-with-lease` against the
  previous task-branch SHA when one exists.

  ## Prune

  Retention (30 days by default) applies to `*-run-NNN` branches. Task branches
  are not deleted by `prune_expired/2` while they remain the canonical pointer
  for a succeeded job inside the retention window.

  ## Push credentials

  Fetch and push run on the host as the Omashiki OS user. Optional
  `[repositories.*].ssh_key` (and `ssh_key_passphrase = "${env:VAR}"`) become
  `GIT_SSH_COMMAND` / `SSH_ASKPASS` on those host commands only. Declaring the
  same material in `[host_credentials.*]` would be wrong twice over — that
  section is harness-shaped and copies into the per-attempt container mount,
  which is exactly where a push credential must never appear. An agent holding
  it could push straight to the canonical remote and bypass the secret, symlink,
  protected-path and size validations above.
  """

  alias Omashiki.Config
  alias Omashiki.Jobs.GitArtifact.MirrorLock
  alias Omashiki.Jobs.{Job, JobAttempt, JobDependency, Validate}
  alias Omashiki.Repo
  import Ecto.Query

  @max_bytes 100 * 1024 * 1024
  @retention_seconds 30 * 24 * 60 * 60
  @mirror_prefix "refs/omashiki-remote/"
  @run_branch_suffix ~r/-run-\d{3}\z/
  # A remote operation that stops to ask for credentials would hold the attempt
  # until its lease expires. Absent credentials must fail it instead.
  @non_interactive [{"GIT_TERMINAL_PROMPT", "0"}]

  defp resolve_base_sha(repo_path, snapshot, base_branch, job_id, opts) do
    case Map.get(snapshot, "base") do
      "dependency:" <> dep_id ->
        resolve_dep_head(repo_path, dep_id, opts)

      "dependency" ->
        resolve_first_succeeded_dep_head(repo_path, job_id, opts)

      _ ->
        resolve_declared_base(repo_path, snapshot, base_branch, opts)
    end
  end

  defp resolve_declared_base(repo_path, snapshot, base_branch, opts) do
    case snapshot_remote(snapshot) do
      remote when is_binary(remote) ->
        git(
          repo_path,
          ["rev-parse", "--verify", "#{@mirror_prefix}heads/#{base_branch}^{commit}"],
          opts
        )

      _ ->
        git(repo_path, ["rev-parse", "--verify", "#{base_branch}^{commit}"], opts)
    end
  end

  defp resolve_first_succeeded_dep_head(repo_path, job_id, opts) do
    edges =
      from(d in JobDependency,
        where: d.job_id == ^job_id,
        order_by: [asc: d.inserted_at, asc: d.id],
        select: d.depends_on_job_id
      )
      |> Repo.all()

    Enum.find_value(edges, {:error, :missing_dependency_head_sha}, fn dep_id ->
      case resolve_dep_head(repo_path, dep_id, opts) do
        {:ok, sha} -> {:ok, sha}
        _ -> nil
      end
    end)
  end

  defp resolve_dep_head(repo_path, dep_id, opts) do
    with %Job{} = dep <- Repo.get(Job, dep_id),
         %JobAttempt{} = attempt <- succeeded_attempt(dep),
         true <- is_binary(attempt.head_sha) do
      git(repo_path, ["rev-parse", "--verify", "#{attempt.head_sha}^{commit}"], opts)
    else
      _ -> {:error, :missing_dependency_head_sha}
    end
  end

  defp succeeded_attempt(%Job{id: job_id, current_attempt: number, status: "succeeded"}) do
    Repo.one(
      from(a in JobAttempt,
        where: a.job_id == ^job_id and a.number == ^number and a.status == "succeeded"
      )
    )
  end

  defp succeeded_attempt(_), do: nil

  @type artifact :: %{
          repo_path: String.t(),
          path: String.t(),
          branch: String.t(),
          task_branch: String.t(),
          run_branch: String.t(),
          base_sha: String.t(),
          remote: String.t() | nil,
          job_id: String.t()
        }

  @doc "Create the isolated attempt worktree from the captured base branch SHA."
  def provision_worktree(job, attempt, opts \\ [])

  def provision_worktree(
        %Job{id: job_id, admitted_repository: snapshot} = job,
        %JobAttempt{number: attempt_number},
        opts
      ) do
    with :ok <- valid_job_id(job_id),
         {:ok, repo_path} <- local_repo_path(job, snapshot),
         {:ok, task_branch} <- snapshot_string(snapshot, "task_branch"),
         {:ok, base_branch} <- snapshot_string(snapshot, "base_branch"),
         :ok <- ensure_mirror(repo_path, snapshot, job, opts),
         :ok <- validate_repo(repo_path),
         :ok <- not_cancelled(opts),
         {:ok, base_sha} <- resolve_base_sha(repo_path, snapshot, base_branch, job_id, opts),
         run_branch <- run_branch_name(task_branch, attempt_number),
         artifact <-
           artifact(
             repo_path,
             job_id,
             task_branch,
             run_branch,
             base_sha,
             snapshot_remote(snapshot)
           ),
         {:ok, artifact} <-
           MirrorLock.with_lock(repo_path, fn ->
             with :ok <- collision_check(artifact, opts),
                  :ok <- File.mkdir_p(Path.dirname(artifact.path)) do
               case git(
                      repo_path,
                      ["worktree", "add", "--quiet", "-b", run_branch, artifact.path, base_sha],
                      opts
                    ) do
                 {:ok, _} ->
                   {:ok, artifact}

                 {:error, {:git_failed, status, output}} ->
                   {:error, {:provision_failed, status, output}}

                 {:error, reason} ->
                   {:error, reason}
               end
             end
           end) do
      {:ok, artifact}
    else
      {:error, {:git_failed, status, output}} -> {:error, {:provision_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  def provision_worktree(_, _, _), do: {:error, :invalid_job_snapshot}

  @doc "Provision a worktree, invoke the container callback, and clean up failures."
  def provision(%Job{} = job, %JobAttempt{} = attempt, opts, callback)
      when is_function(callback, 1) do
    with {:ok, artifact} <- provision_worktree(job, attempt, opts) do
      case safe_callback(callback, artifact) do
        {:ok, result} ->
          {:ok, Map.put(result, :artifact, artifact)}

        {:error, reason} ->
          _ = cleanup(artifact, preserve_branch: false, git_env: Keyword.get(opts, :git_env, []))
          {:error, reason}
      end
    end
  end

  @doc """
  Finalize an artifact, committing safe dirty output and returning Git metadata.

  The push to the canonical remote is the last step, after every safety
  validation. Do not reorder it: the remote is shared by the cluster, so content
  that failed the secret, symlink, protected-path or size check must never reach
  it.
  """
  def finalize(%{} = artifact, %Job{} = job, opts \\ []) do
    remote = Map.get(artifact, :remote)
    update_task_branch = Keyword.get(opts, :update_task_branch, false)

    with :ok <- not_cancelled(opts),
         {:ok, paths} <- dirty_paths(artifact.path, opts),
         {:ok, changed_bytes} <- changed_bytes(artifact.path, paths),
         :ok <- Validate.scan(artifact.path, paths, changed_bytes, opts),
         {:ok, previous_head} <- commit_if_dirty(artifact, job, paths, changed_bytes, opts),
         {:ok, head_sha} <- git(artifact.path, ["rev-parse", "HEAD"], opts),
         :ok <- verify_head(artifact, head_sha, previous_head, opts),
         :ok <- publish_run_branch(artifact, remote, job, opts),
         :ok <-
           maybe_update_task_branch(artifact, remote, head_sha, update_task_branch, job, opts) do
      result_branch =
        if update_task_branch, do: artifact.task_branch, else: artifact.run_branch

      {:ok,
       %{
         remote: remote,
         branch: result_branch,
         task_branch: artifact.task_branch,
         run_branch: artifact.run_branch,
         base_sha: artifact.base_sha,
         head_sha: head_sha,
         worktree_clean: true,
         result: %{
           "job_id" => to_string(job.id),
           "remote" => remote,
           "branch" => result_branch,
           "task_branch" => artifact.task_branch,
           "run_branch" => artifact.run_branch,
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
        delete_branch(artifact.repo_path, artifact.run_branch, opts)
      end

    case {worktree_result, branch_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _} -> {:error, reason}
      {_, {:error, reason}} -> {:error, reason}
    end
  end

  @doc """
  Delete expired run branches whose tip is older than the retention period.

  Pass `:remote` to retire the artifacts the cluster can actually see. Task
  branches are never removed by this sweep.
  """
  def prune_expired(repo_path, opts \\ []) when is_binary(repo_path) do
    cutoff = Keyword.get(opts, :cutoff, System.system_time(:second) - @retention_seconds)
    remote = Keyword.get(opts, :remote)

    with :ok <- validate_repo(repo_path),
         {:ok, refs} <- retention_candidates(repo_path, remote, opts) do
      refs
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, pruned} ->
        case String.split(line, "\t", parts: 2) do
          [branch, timestamp] when branch != "" ->
            branch = normalize_mirror_branch(branch)

            if parse_integer(timestamp) < cutoff do
              case retire_branch(repo_path, remote, branch, opts) do
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

  defp retention_candidates(repo_path, nil, opts) do
    with {:ok, output} <-
           git(
             repo_path,
             ["for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)", "refs/heads"],
             opts
           ) do
      {:ok, filter_run_branch_lines(output)}
    end
  end

  # `ls-remote` carries no committer date, so mirror the remote's run refs
  # into a private namespace and age them out from there. `--prune` drops the
  # mirrors of branches a previous sweep already retired.
  defp retention_candidates(repo_path, remote, opts) do
    with {:ok, remote_opts} <- remote_git_opts(opts, repo_path),
         {:ok, _} <-
           git(
             repo_path,
             [
               "fetch",
               "--quiet",
               "--prune",
               remote,
               "+refs/heads/*:#{@mirror_prefix}heads/*"
             ],
             remote_opts
           ),
         {:ok, output} <-
           git(
             repo_path,
             [
               "for-each-ref",
               "--format=%(refname:lstrip=2)\t%(committerdate:unix)",
               "#{@mirror_prefix}heads/"
             ],
             opts
           ) do
      {:ok, filter_run_branch_lines(output)}
    end
  end

  defp filter_run_branch_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(fn line ->
      case String.split(line, "\t", parts: 2) do
        [branch, _] -> Regex.match?(@run_branch_suffix, branch)
        _ -> false
      end
    end)
    |> Enum.join("\n")
  end

  defp retire_branch(repo_path, nil, branch, opts), do: delete_branch(repo_path, branch, opts)

  defp retire_branch(repo_path, remote, branch, opts) do
    with :ok <- delete_remote_branch(repo_path, remote, branch, opts) do
      delete_branch(repo_path, branch, opts)
    end
  end

  defp delete_remote_branch(repo_path, remote, branch, opts) do
    with {:ok, remote_opts} <- remote_git_opts(opts, repo_path) do
      case git(repo_path, ["push", remote, "--delete", "refs/heads/#{branch}"], remote_opts) do
        {:ok, _} ->
          :ok

        {:error, {:git_failed, _status, output}} ->
          if String.contains?(output, "remote ref does not exist"),
            do: :ok,
            else: {:error, {:branch_cleanup_failed, {:git_failed, output}}}

        {:error, reason} ->
          {:error, {:branch_cleanup_failed, reason}}
      end
    end
  end

  defp artifact(repo_path, job_id, task_branch, run_branch, base_sha, remote) do
    worktree_dir = String.replace(run_branch, "/", "-")

    %{
      repo_path: repo_path,
      path: Path.join(repo_path, Path.join(".omashiki-worktrees", worktree_dir)),
      branch: run_branch,
      task_branch: task_branch,
      run_branch: run_branch,
      base_sha: base_sha,
      remote: remote,
      job_id: to_string(job_id)
    }
  end

  defp snapshot_remote(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, "remote") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp snapshot_remote(_), do: nil

  defp collision_check(%{repo_path: repo_path, path: path, run_branch: run_branch}, opts) do
    cond do
      File.exists?(path) -> {:error, {:collision, :worktree, path}}
      ref_exists?(repo_path, run_branch, opts) -> {:error, {:collision, :branch, run_branch}}
      true -> :ok
    end
  end

  defp publish_run_branch(_artifact, nil, _job, _opts), do: :ok

  defp publish_run_branch(artifact, remote, job, opts) do
    ref = run_branch_ref(artifact.run_branch)

    with {:ok, remote_opts} <- remote_git_opts(opts, job) do
      case git(
             artifact.path,
             ["push", "--force-with-lease=#{ref}:", remote, "#{ref}:#{ref}"],
             remote_opts
           ) do
        {:ok, _} ->
          :ok

        {:error, {:git_failed, status, output}} ->
          if String.contains?(output, "[rejected]"),
            do: {:error, {:collision, :remote, artifact.run_branch}},
            else: {:error, {:push_failed, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_update_task_branch(_artifact, _remote, _head_sha, false, _job, _opts), do: :ok

  defp maybe_update_task_branch(artifact, nil, head_sha, true, _job, opts) do
    case git(artifact.repo_path, ["branch", "-f", artifact.task_branch, head_sha], opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_update_task_branch(artifact, remote, head_sha, true, job, opts) do
    ref = task_branch_ref(artifact.task_branch)

    with {:ok, remote_opts} <- remote_git_opts(opts, job),
         {:ok, lease} <-
           task_branch_push_lease(artifact.repo_path, remote, artifact.task_branch, remote_opts),
         {:ok, _} <-
           git(artifact.path, ["push", lease, remote, "#{head_sha}:#{ref}"], remote_opts) do
      :ok
    else
      {:error, {:git_failed, status, output}} ->
        if String.contains?(output, "[rejected]"),
          do: {:error, {:collision, :remote, artifact.task_branch}},
          else: {:error, {:push_failed, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp task_branch_push_lease(repo_path, remote, task_branch, opts) do
    ref = task_branch_ref(task_branch)

    case git(repo_path, ["ls-remote", remote, ref], opts) do
      {:ok, ""} ->
        {:ok, "--force-with-lease=#{ref}:"}

      {:ok, output} ->
        sha =
          output
          |> String.split("\n", trim: true)
          |> Enum.find_value("", fn line ->
            case String.split(line, "\t", parts: 2) do
              [hash, ^ref] -> hash
              _ -> nil
            end
          end)

        {:ok,
         if(sha == "",
           do: "--force-with-lease=#{ref}:",
           else: "--force-with-lease=#{ref}:#{sha}"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_branch_name(task_branch, attempt_number),
    do: "#{task_branch}-run-#{pad_attempt(attempt_number)}"

  defp pad_attempt(number) when is_integer(number),
    do: String.pad_leading(Integer.to_string(number), 3, "0")

  defp run_branch_ref(branch), do: "refs/heads/#{branch}"
  defp task_branch_ref(branch), do: "refs/heads/#{branch}"

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
           true <- branch == artifact.run_branch,
           {:ok, branch_sha} <-
             git(artifact.repo_path, ["rev-parse", "refs/heads/#{artifact.run_branch}"], opts),
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

  @doc """
  Reclaim worktree entries whose directory no longer exists, for every declared
  repository.

  Repo-wide by nature, so it belongs here — at boot, before any attempt is in
  flight — and not in the per-job cleanup path, where it would race concurrent
  provisioning.
  """
  def prune_worktrees(opts \\ []) do
    Omashiki.Config.repositories()
    |> Enum.each(fn repository ->
      path = Map.get(repository, :path, Map.get(repository, "path"))

      if is_binary(path) and validate_repo(path) == :ok do
        _ = git(path, ["worktree", "prune"], opts)
      end
    end)

    :ok
  end

  defp cleanup_worktree(%{repo_path: repo_path, path: path}, opts) do
    if File.exists?(path) do
      case git(repo_path, ["worktree", "remove", "--force", path], opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:cleanup_failed, reason}}
      end
    else
      :ok
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
    if git_checkout?(path), do: :ok, else: {:error, :repository_unavailable}
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

  defp git_clone(remote, path, opts) do
    case System.cmd("git", ["clone", "--quiet", "--no-checkout", remote, path],
           env: Keyword.get(opts, :git_env, []),
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, status, summary(output)}}
    end
  rescue
    error -> {:error, {:git_exception, inspect(error)}}
  end

  defp local_repo_path(%Job{repository: name}, snapshot) when is_binary(name) and name != "" do
    case snapshot_remote(snapshot) do
      remote when is_binary(remote) ->
        case Config.get_repository(name) do
          %Config.Repository{path: path} when is_binary(path) and path != "" -> {:ok, path}
          _ -> snapshot_string(snapshot, "path")
        end

      _ ->
        snapshot_string(snapshot, "path")
    end
  end

  defp local_repo_path(_job, snapshot), do: snapshot_string(snapshot, "path")

  defp ssh_env(%Job{} = job), do: ssh_env_for_repository(repo_for(job))

  defp ssh_env(path) when is_binary(path) do
    repository = Enum.find(Config.repositories(), &(&1.path == path))
    ssh_env_for_repository(repository)
  end

  defp ssh_env(_), do: {:ok, []}

  defp ssh_env_for_repository(repository) do
    case repository do
      %Config.Repository{ssh_key: key} = repo when is_binary(key) and key != "" ->
        ssh_env_for_key(key, repo.ssh_key_passphrase)

      _ ->
        {:ok, []}
    end
  end

  defp ssh_env_for_key(key, nil) do
    {:ok,
     [
       {"GIT_SSH_COMMAND",
        "ssh -i #{key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes"}
     ]}
  end

  defp ssh_env_for_key(key, passphrase_ref) when is_binary(passphrase_ref) do
    case resolve_passphrase_ref(passphrase_ref) do
      {:ok, secret} ->
        {:ok,
         [
           {"GIT_SSH_COMMAND",
            "ssh -i #{key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"},
           {"SSH_ASKPASS", askpass_path()},
           {"SSH_ASKPASS_REQUIRE", "force"},
           {"DISPLAY", "none"},
           {"OMASHIKI_GIT_ASKPASS_PASSPHRASE", secret}
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_passphrase_ref(ref) do
    case Regex.run(~r/^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/, ref) do
      [_, name] ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:git_auth, :passphrase_unset}}
        end

      _ ->
        {:error, {:git_auth, :passphrase_unset}}
    end
  end

  defp askpass_path do
    Path.join(:code.priv_dir(:omashiki), "git-ssh-askpass.sh")
  end

  defp repo_for(%Job{repository: name}) when is_binary(name) and name != "",
    do: Config.get_repository(name)

  defp repo_for(_), do: nil

  defp remote_git_opts(opts, source) do
    with {:ok, extra} <- ssh_env(source) do
      env =
        opts
        |> Keyword.get(:git_env, [])
        |> merge_git_env(extra)
        |> merge_git_env(@non_interactive)

      {:ok,
       opts
       |> Keyword.put(:git_env, env)
       |> Keyword.put(:remote_git, true)}
    end
  end

  defp ensure_mirror(repo_path, snapshot, job, opts) do
    case snapshot_remote(snapshot) do
      nil ->
        :ok

      remote ->
        with :ok <- validate_managed_mirror_path(repo_path),
             {:ok, remote_opts} <- remote_git_opts(opts, job),
             :ok <-
               MirrorLock.with_lock(repo_path, fn ->
                 with :ok <- ensure_clone(repo_path, remote, remote_opts) do
                   fetch_mirror(repo_path, remote, remote_opts)
                 end
               end) do
          :ok
        end
    end
  end

  defp ensure_clone(repo_path, remote, opts) do
    cond do
      git_checkout?(repo_path) ->
        :ok

      File.exists?(repo_path) ->
        {:error, :repository_unavailable}

      true ->
        tmp = repo_path <> ".clone-#{System.unique_integer([:positive])}"

        case File.mkdir_p(Path.dirname(repo_path)) do
          :ok ->
            case git_clone(remote, tmp, opts) do
              {:ok, _} ->
                case File.rename(tmp, repo_path) do
                  :ok ->
                    :ok

                  {:error, :eexist} ->
                    File.rm_rf(tmp)
                    :ok

                  {:error, reason} ->
                    File.rm_rf(tmp)
                    {:error, {:clone_failed, reason}}
                end

              error ->
                File.rm_rf(tmp)
                error
            end

          {:error, reason} ->
            {:error, {:clone_failed, reason}}
        end
    end
  end

  defp fetch_mirror(repo_path, remote, opts) do
    case git(
           repo_path,
           ["fetch", "--prune", remote, "+refs/heads/*:#{@mirror_prefix}heads/*"],
           opts
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  defp git_checkout?(path) do
    File.dir?(path) and git(path, ["rev-parse", "--is-inside-work-tree"], []) == {:ok, "true"}
  end

  defp validate_managed_mirror_path(path) do
    root = Path.join([System.user_home!(), ".cache", "omashiki", "mirrors"])
    path = Path.expand(path)

    if contained?(path, root) and symlink_in_absolute_path?(path),
      do: {:error, :repository_unavailable},
      else: :ok
  end

  defp merge_git_env(existing, additions) do
    Enum.uniq_by(additions ++ existing, &elem(&1, 0))
  end

  defp symlink_in_absolute_path?(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.any?(fn component ->
      match?({:ok, %File.Stat{type: :symlink}}, File.lstat(component))
    end)
  end

  defp git(path, args, opts) do
    args =
      if Keyword.get(opts, :remote_git, false),
        do: ["-c", "core.hooksPath=/dev/null" | args],
        else: args

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

  defp normalize_mirror_branch(branch) do
    String.replace_prefix(branch, "heads/", "")
  end

  defp contained?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
