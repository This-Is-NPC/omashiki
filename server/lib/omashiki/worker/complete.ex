defmodule Omashiki.Worker.Complete do
  @moduledoc """
  Terminal execution result keyed by sink.

  JSON-serialisable sum type for the worker transport protocol.
  """

  import Ecto.Query

  alias Omashiki.Jobs.{Job, JobAttempt, Statuses}
  alias Omashiki.Repo

  @terminal Statuses.terminal()

  @type kind :: :git | :files | :none | :error

  @type t :: %__MODULE__{
          kind: kind(),
          remote: String.t() | nil,
          branch: String.t() | nil,
          base_sha: String.t() | nil,
          head_sha: String.t() | nil,
          changed_bytes: non_neg_integer() | nil,
          blob_digest: String.t() | nil,
          blob_path: String.t() | nil,
          code: String.t() | nil,
          message: String.t() | nil,
          details: map() | nil,
          summary: String.t() | nil,
          changes: map() | nil,
          compare_url: String.t() | nil
        }

  defstruct [
    :kind,
    :remote,
    :branch,
    :base_sha,
    :head_sha,
    :changed_bytes,
    :blob_digest,
    :blob_path,
    :code,
    :message,
    :details,
    :summary,
    :changes,
    :compare_url
  ]

  @doc "Build a complete value from a terminal job row."
  def from_job(%Job{status: "succeeded"} = job), do: from_succeeded_job(job)

  def from_job(%Job{status: status, terminal_error: error})
      when status in ["failed", "cancelled"] and is_map(error) do
    %__MODULE__{
      kind: :error,
      code: error_code(error),
      message: error_message(error),
      details: error_details(error)
    }
  end

  def from_job(%Job{status: status}) when status in @terminal do
    %__MODULE__{
      kind: :error,
      code: "terminal_without_error",
      message: "job reached #{status} without terminal_error",
      details: nil
    }
  end

  @doc "Encode a complete value for JSON transport."
  def to_map(%__MODULE__{kind: :git} = complete) do
    %{
      "kind" => "git",
      "remote" => complete.remote,
      "branch" => complete.branch,
      "base_sha" => complete.base_sha,
      "head_sha" => complete.head_sha
    }
    |> maybe_put("summary", complete.summary)
    |> maybe_put("changes", complete.changes)
    |> maybe_put("compare_url", complete.compare_url)
  end

  def to_map(%__MODULE__{kind: :files} = complete) do
    base = %{
      "kind" => "files",
      "changed_bytes" => complete.changed_bytes,
      "blob_digest" => complete.blob_digest
    }

    case complete.blob_path do
      path when is_binary(path) -> Map.put(base, "blob_path", path)
      _ -> base
    end
  end

  def to_map(%__MODULE__{kind: :none, changed_bytes: changed_bytes}) do
    %{"kind" => "none", "changed_bytes" => changed_bytes}
  end

  def to_map(%__MODULE__{kind: :error} = complete) do
    base = %{
      "kind" => "error",
      "code" => complete.code,
      "message" => complete.message
    }

    case complete.details do
      %{} = details -> Map.put(base, "details", details)
      _ -> base
    end
  end

  @doc "Decode a complete value from JSON transport."
  def from_map(%{"kind" => "git"} = map) do
    {:ok,
     %__MODULE__{
       kind: :git,
       remote: Map.get(map, "remote"),
       branch: map["branch"],
       base_sha: map["base_sha"],
       head_sha: map["head_sha"],
       summary: Map.get(map, "summary"),
       changes: Map.get(map, "changes"),
       compare_url: Map.get(map, "compare_url")
     }}
  end

  def from_map(%{"kind" => "files"} = map) do
    {:ok,
     %__MODULE__{
       kind: :files,
       changed_bytes: map["changed_bytes"],
       blob_digest: map["blob_digest"],
       blob_path: Map.get(map, "blob_path")
     }}
  end

  def from_map(%{"kind" => "none", "changed_bytes" => changed_bytes}) do
    {:ok, %__MODULE__{kind: :none, changed_bytes: changed_bytes}}
  end

  def from_map(%{"kind" => "error", "code" => code, "message" => message} = map) do
    {:ok,
     %__MODULE__{
       kind: :error,
       code: code,
       message: message,
       details: Map.get(map, "details")
     }}
  end

  def from_map(_map), do: {:error, :invalid_complete}

  defp from_succeeded_job(%Job{} = job) do
    case admitted_sink(job) do
      {:ok, "git"} ->
        with %JobAttempt{} = attempt <- terminal_attempt(job) do
          %__MODULE__{
            kind: :git,
            remote: git_remote(job),
            branch: attempt.branch,
            base_sha: attempt.base_sha,
            head_sha: attempt.head_sha,
            summary: attempt.summary,
            changes: attempt.changes,
            compare_url: attempt.compare_url
          }
        else
          _ ->
            %__MODULE__{
              kind: :error,
              code: "missing_git_attempt",
              message: "succeeded git job has no terminal attempt with git fields",
              details: nil
            }
        end

      {:ok, "files"} ->
        result = job.terminal_result || %{}

        %__MODULE__{
          kind: :files,
          changed_bytes: Map.get(result, "changed_bytes"),
          blob_digest: Map.get(result, "blob_digest"),
          blob_path: Map.get(result, "blob_path")
        }

      {:ok, "none"} ->
        result = job.terminal_result || %{}

        %__MODULE__{
          kind: :none,
          changed_bytes: Map.get(result, "changed_bytes", 0)
        }

      _ ->
        %__MODULE__{
          kind: :error,
          code: "invalid_sink",
          message: "succeeded job has no admitted sink",
          details: nil
        }
    end
  end

  defp admitted_sink(%Job{admitted_environment: env}) when is_map(env) do
    case Map.get(env, "sink") do
      sink when sink in ["git", "files", "none"] -> {:ok, sink}
      _ -> :error
    end
  end

  defp admitted_sink(_), do: :error

  defp terminal_attempt(%Job{id: job_id, current_attempt: number})
       when is_integer(number) and number > 0 do
    Repo.one(
      from(a in JobAttempt,
        where: a.job_id == ^job_id and a.number == ^number and a.status == "succeeded",
        limit: 1
      )
    )
  end

  defp terminal_attempt(_), do: nil

  defp git_remote(%Job{terminal_result: %{"remote" => remote}}) when is_binary(remote),
    do: remote

  defp git_remote(%Job{admitted_repository: %{"remote" => remote}}) when is_binary(remote),
    do: remote

  defp git_remote(_), do: nil

  defp error_code(%{"code" => code}) when is_binary(code), do: code
  defp error_code(%{code: code}) when is_binary(code), do: code
  defp error_code(_), do: "unknown"

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error) when is_map(error), do: inspect(error)
  defp error_message(_), do: "unknown error"

  defp error_details(%{"details" => details}) when is_map(details), do: details
  defp error_details(%{details: details}) when is_map(details), do: details
  defp error_details(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
