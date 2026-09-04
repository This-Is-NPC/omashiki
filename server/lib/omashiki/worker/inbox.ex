defmodule Omashiki.Worker.Inbox do
  @moduledoc false

  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt}
  alias Omashiki.Repo
  alias Omashiki.Worker.{Complete, Offer, Presence}

  @terminal ~w(succeeded failed cancelled)

  @doc "Register worker capacity and optionally claim the next queued job."
  def poll(machine_id, free_slots) when is_binary(machine_id) do
    Presence.touch(machine_id, %{
      last_poll_at: now(),
      free_slots: free_slots,
      metadata: %{}
    })

    runner_id = "worker:#{machine_id}"

    case Jobs.claim_next(runner_id, free_slots: free_slots) do
      {:ok, :empty} ->
        {:ok, %{offer: nil}}

      {:ok, %JobAttempt{} = attempt} ->
        job = Repo.get!(Job, attempt.job_id)
        {:ok, %{offer: Offer.to_map(Offer.from_claimed(job, attempt))}}

      {:error, :capacity_exhausted} ->
        {:ok, %{offer: nil}}

      other ->
        other
    end
  end

  @doc "Renew a lease; piggy-back cancel when the job is already terminal."
  def heartbeat(attempt_id, lease_token)
      when is_binary(attempt_id) and is_binary(lease_token) do
    case Jobs.heartbeat(attempt_id, lease_token) do
      {:ok, _} ->
        if cancel?(attempt_id), do: {:ok, :cancel}, else: {:ok, :ok}

      {:error, :attempt_not_active} ->
        {:ok, :cancel}

      other ->
        other
    end
  end

  @doc "Apply a worker-complete payload to the manager job row."
  def complete(attempt_id, lease_token, complete_map)
      when is_binary(attempt_id) and is_binary(lease_token) and is_map(complete_map) do
    with {:ok, complete} <- Complete.from_map(complete_map),
         %JobAttempt{job_id: job_id} <- Repo.get(JobAttempt, attempt_id) || {:error, :not_found},
         {:ok, status, attrs} <- completion_args(complete, job_id) do
      Jobs.complete(attempt_id, lease_token, status, attrs)
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
    end
  end

  @doc "Persist a files-sink blob on the manager before completion."
  def put_blob(job_id, digest, binary)
      when is_binary(job_id) and is_binary(digest) and is_binary(binary) do
    computed = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    expected = String.downcase(digest)

    if computed != expected do
      {:error, :digest_mismatch}
    else
      dir = Path.join(blob_root(), job_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "artifact.tar.gz")
      :ok = File.write!(path, binary)
      {:ok, path}
    end
  end

  defp completion_args(%Complete{kind: :git} = complete, _job_id) do
    result =
      %{
        "remote" => complete.remote,
        "branch" => complete.branch,
        "base_sha" => complete.base_sha,
        "head_sha" => complete.head_sha
      }
      |> drop_nil_values()

    {:ok, "succeeded",
     %{
       branch: complete.branch,
       base_sha: complete.base_sha,
       head_sha: complete.head_sha,
       worktree_clean: true,
       result: result
     }}
  end

  defp completion_args(%Complete{kind: :files} = complete, job_id) do
    with {:ok, blob_path} <- blob_path_for(job_id, complete.blob_digest) do
      {:ok, "succeeded",
       %{
         result: %{
           "sink" => "files",
           "changed_bytes" => complete.changed_bytes,
           "blob_digest" => complete.blob_digest,
           "blob_path" => blob_path,
           "job_id" => job_id
         }
       }}
    end
  end

  defp completion_args(%Complete{kind: :none, changed_bytes: changed_bytes}, job_id) do
    {:ok, "succeeded",
     %{
       result: %{
         "sink" => "none",
         "changed_bytes" => changed_bytes,
         "job_id" => job_id
       }
     }}
  end

  defp completion_args(%Complete{kind: :error} = complete, _job_id) do
    {:ok, "failed",
     %{
       error: %{
         "code" => complete.code,
         "message" => complete.message,
         "details" => complete.details || %{}
       }
     }}
  end

  defp blob_path_for(job_id, digest) when is_binary(digest) do
    path = Path.join([blob_root(), job_id, "artifact.tar.gz"])

    cond do
      not File.exists?(path) ->
        {:error, :blob_missing}

      verify_digest(path, digest) == :ok ->
        {:ok, path}

      true ->
        {:error, :digest_mismatch}
    end
  end

  defp blob_path_for(_job_id, _), do: {:error, :blob_missing}

  defp verify_digest(path, digest) do
    computed =
      path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    if computed == String.downcase(digest), do: :ok, else: :error
  end

  defp blob_root, do: Path.join(System.tmp_dir!(), "omashiki-blobs")

  defp cancel?(attempt_id) do
    case Repo.get(JobAttempt, attempt_id) do
      %JobAttempt{job_id: job_id} ->
        case Repo.get(Job, job_id) do
          %Job{status: status} when status in @terminal -> true
          _ -> false
        end

      _ ->
        true
    end
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
