defmodule Omashiki.Jobs.HeldOutput do
  @moduledoc """
  Output held for review on the node that produced it.

  When the secret scan is the only check that refuses an attempt's output and
  the environment has `secret_scan = "review"`, the node keeps the output
  where the attempt left it — the work directory of a `files` or `none` job,
  the worktree and run branch of a `git` job — and writes a record of it. The
  container is removed and the slot released; the job waits in `review`.

  A record is a JSON file in `root/0`, readable only by the house user. It
  names the attempt, the fence the house gave it, the manager that offered it
  (none on an embedded house), and where the output is. Container reclaim,
  stale-attempt recovery and boot cleanup never touch the output, so a record
  and its output survive a restart of the node.

  `Omashiki.Jobs.HeldOutput.Sweeper` asks the house what to do with each
  record, then calls `publish/1` and `finish/1`, or `discard/1`.
  """

  require Logger

  alias Omashiki.Jobs.{Failure, GitArtifact, Job, JobAttempt, WorkArtifact}
  alias Omashiki.Worker.Complete

  @enforce_keys [
    :attempt_id,
    :job_id,
    :attempt_number,
    :repository,
    :token,
    :manager_id,
    :sink,
    :artifact,
    :summary
  ]
  defstruct @enforce_keys ++ [complete: nil]

  @type t :: %__MODULE__{
          attempt_id: String.t(),
          job_id: String.t(),
          attempt_number: pos_integer(),
          repository: String.t() | nil,
          token: String.t(),
          manager_id: String.t() | nil,
          sink: String.t(),
          artifact: map(),
          summary: String.t() | nil,
          complete: Complete.t() | nil
        }

  @doc "True when the environment holds output that `reason` refused for review."
  def review?(environment, {:secret_found, _findings}),
    do: Map.get(environment, "secret_scan") == "review"

  def review?(_environment, _reason), do: false

  @doc "Directory of the records: `:held_output_root`, or `~/.cache/omashiki/held`."
  def root do
    case Application.get_env(:omashiki, :held_output_root) do
      root when is_binary(root) and root != "" -> Path.expand(root)
      _ -> Path.join([System.user_home!(), ".cache", "omashiki", "held"])
    end
  end

  @doc """
  Record the output of `attempt`, refused only by the secret scan.

  `opts` carries `:token` (the attempt's fence), `:sink`, `:artifact`,
  `:summary` and, on a worker, the `:manager_id` that offered the attempt.
  """
  @spec hold(Job.t(), JobAttempt.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def hold(%Job{} = job, %JobAttempt{} = attempt, opts) do
    record = %__MODULE__{
      attempt_id: attempt.id,
      job_id: job.id,
      attempt_number: attempt.number,
      repository: job.repository,
      token: Keyword.fetch!(opts, :token),
      manager_id: Keyword.get(opts, :manager_id),
      sink: Keyword.fetch!(opts, :sink),
      artifact: Keyword.fetch!(opts, :artifact),
      summary: Keyword.get(opts, :summary)
    }

    # The attempt id names the record file.
    with {:ok, _uuid} <- Ecto.UUID.cast(attempt.id),
         :ok <- write(record) do
      {:ok, record}
    else
      :error -> {:error, :invalid_attempt_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every record on this node. An unreadable file is logged and skipped."
  @spec list() :: [t()]
  def list do
    case File.ls(root()) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            String.ends_with?(name, ".json"),
            record = read(Path.join(root(), name)),
            do: record

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Publish approved output through the sink's normal finalization, without
  the secret scan, and keep the complete to send in the record. A restart
  then resends that complete instead of publishing twice.
  """
  @spec publish(t()) :: {:ok, t()} | {:error, term()}
  def publish(%__MODULE__{complete: nil} = record) do
    opts = [update_task_branch: true, secret_scan: false, manager_id: record.manager_id]

    complete =
      case finalize(record, opts) do
        {:ok, final} ->
          Complete.from_finalize(record.sink, final, record.summary)

        {:error, reason} ->
          Complete.from_error(
            :error,
            Failure.error({:finalization_failed, reason}, "finalization")
          )
      end

    record = %{record | complete: complete}
    with :ok <- write(record), do: {:ok, record}
  end

  @doc """
  Forget a record whose complete the house accepted. Published Git output
  keeps its run branch; the worktree and any work directory go.
  """
  @spec finish(t()) :: :ok
  def finish(%__MODULE__{complete: %Complete{kind: kind}} = record),
    do: remove(record, kind != :error)

  @doc "Remove the output and its record: the job was rejected or cancelled."
  @spec discard(t()) :: :ok
  def discard(%__MODULE__{} = record), do: remove(record, false)

  defp finalize(%{sink: "git"} = record, opts),
    do: GitArtifact.finalize(record.artifact, job(record), opts)

  defp finalize(record, opts), do: WorkArtifact.finalize(record.artifact, job(record), opts)

  defp job(record) do
    %Job{id: record.job_id, current_attempt: record.attempt_number, repository: record.repository}
  end

  defp remove(record, preserve_branch?) do
    result =
      case record.sink do
        "git" -> GitArtifact.cleanup(record.artifact, preserve_branch: preserve_branch?)
        _sink -> WorkArtifact.cleanup(record.artifact)
      end

    if result != :ok,
      do: Logger.warning("held output of #{record.attempt_id} not removed: #{inspect(result)}")

    _ = File.rm(path(record.attempt_id))
    :ok
  end

  defp write(record) do
    encoded =
      Jason.encode!(%{
        "attempt_id" => record.attempt_id,
        "job_id" => record.job_id,
        "attempt_number" => record.attempt_number,
        "repository" => record.repository,
        "token" => record.token,
        "manager_id" => record.manager_id,
        "sink" => record.sink,
        "artifact" => record.artifact,
        "summary" => record.summary,
        "complete" => record.complete && Complete.to_map(record.complete)
      })

    file = path(record.attempt_id)
    partial = file <> ".partial"

    with :ok <- File.mkdir_p(root()),
         :ok <- File.chmod(root(), 0o700),
         :ok <- File.write(partial, encoded),
         :ok <- File.chmod(partial, 0o600) do
      File.rename(partial, file)
    end
  end

  defp read(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, map} <- Jason.decode(raw),
         {:ok, complete} <- decode_complete(map["complete"]) do
      %__MODULE__{
        attempt_id: map["attempt_id"],
        job_id: map["job_id"],
        attempt_number: map["attempt_number"],
        repository: map["repository"],
        token: map["token"],
        manager_id: map["manager_id"],
        sink: map["sink"],
        artifact:
          Map.new(map["artifact"], fn {key, value} -> {String.to_existing_atom(key), value} end),
        summary: map["summary"],
        complete: complete
      }
    else
      error ->
        Logger.warning("held output record #{file} is unreadable: #{inspect(error)}")
        nil
    end
  end

  defp decode_complete(nil), do: {:ok, nil}
  defp decode_complete(map), do: Complete.from_map(map)

  defp path(attempt_id), do: Path.join(root(), "#{attempt_id}.json")
end
