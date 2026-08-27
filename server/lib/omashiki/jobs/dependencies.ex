defmodule Omashiki.Jobs.Dependencies do
  @moduledoc false

  import Ecto.Query

  alias Omashiki.Jobs.{DispatchWorker, Job, JobAttempt, JobDependency, JobEvent}
  alias Omashiki.Repo

  @terminal ~w(succeeded failed cancelled)

  def notify_dependents!(%Job{} = dependency, unlock_event_id) do
    dependents =
      from(d in JobDependency,
        join: j in Job,
        on: j.id == d.job_id,
        where: d.depends_on_job_id == ^dependency.id and j.status == "blocked",
        order_by: [asc: j.priority, asc: j.inserted_at, asc: j.id],
        select: j,
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    Enum.each(dependents, &evaluate_blocked_dependent!(&1, unlock_event_id))
    :ok
  end

  defp evaluate_blocked_dependent!(%Job{} = dependent, unlock_event_id) do
    case dependency_resolution(dependent) do
      {:cancel, dep} ->
        cancel_dependent!(dependent, dep)

      :blocked ->
        :ok

      {:unlock, artifacts, depends_on} ->
        unlock_dependent!(dependent, artifacts, depends_on, unlock_event_id)
    end
  end

  defp dependency_resolution(%Job{id: job_id}) do
    edges = dependency_edges(job_id)

    if edges == [] do
      :blocked
    else
      dep_jobs = load_dependency_jobs(edges)

      cancel_dep =
        Enum.find_value(edges, fn {dep_id, on_failure} ->
          dep = Map.fetch!(dep_jobs, dep_id)

          if dep.status in ~w(failed cancelled) and on_failure == "cancel" do
            dep
          end
        end)

      cond do
        cancel_dep ->
          {:cancel, cancel_dep}

        all_edges_satisfied?(edges, dep_jobs) ->
          artifacts = build_dependency_artifacts(edges, dep_jobs)
          depends_on = Enum.map(edges, fn {dep_id, _} -> dep_id end)
          {:unlock, artifacts, depends_on}

        true ->
          :blocked
      end
    end
  end

  defp all_edges_satisfied?(edges, dep_jobs) do
    Enum.all?(edges, fn {dep_id, on_failure} ->
      case Map.fetch!(dep_jobs, dep_id).status do
        "succeeded" -> true
        status when status in ~w(failed cancelled) -> on_failure == "proceed"
        _ -> false
      end
    end)
  end

  defp dependency_edges(job_id) do
    from(d in JobDependency,
      where: d.job_id == ^job_id,
      select: {d.depends_on_job_id, d.on_failure}
    )
    |> Repo.all()
  end

  def artifacts_for(edges) when is_list(edges) do
    build_dependency_artifacts(edges, load_dependency_jobs(edges))
  end

  defp load_dependency_jobs(edges) do
    ids = Enum.map(edges, fn {dep_id, _} -> dep_id end)

    from(j in Job, where: j.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp build_dependency_artifacts(edges, dep_jobs) do
    Enum.map(edges, fn {dep_id, _} ->
      dep = Map.fetch!(dep_jobs, dep_id)
      attempt = terminal_attempt(dep)

      %{
        "id" => dep.id,
        "branch" => attempt && attempt.branch,
        "head_sha" => attempt && attempt.head_sha,
        "result" => (attempt && attempt.result) || dep.terminal_result,
        "status" => dep.status
      }
    end)
  end

  defp terminal_attempt(%Job{id: job_id, current_attempt: number}) do
    Repo.one(
      from(a in JobAttempt,
        where: a.job_id == ^job_id and a.number == ^number and a.status in ^@terminal
      )
    )
  end

  defp unlock_dependent!(%Job{} = dependent, artifacts, depends_on, unlock_event_id) do
    now = DateTime.utc_now(:microsecond)

    updated =
      update_job!(dependent, %{
        status: "queued",
        queued_at: now,
        dependency_artifacts: artifacts
      })

    attempt = current_attempt!(updated)
    update_attempt!(attempt, %{status: "queued"})

    record_event!(updated, "queued", %{
      "depends_on" => depends_on,
      "unlock_event_id" => unlock_event_id
    })

    enqueue!(updated)
  end

  defp cancel_dependent!(%Job{} = dependent, %Job{} = dep) do
    now = DateTime.utc_now(:microsecond)
    error = dependency_terminal_error(dep)

    updated =
      update_job!(dependent, %{
        status: "cancelled",
        finished_at: now,
        terminal_result: nil,
        terminal_error: error
      })

    attempt = current_attempt!(updated)

    completed_attempt =
      update_attempt!(attempt, %{
        status: "cancelled",
        finished_at: now,
        error: error,
        capacity_reserved: false,
        lease_token: nil,
        lease_expires_at: nil
      })

    record_event!(updated, "cancelled", %{"error_code" => error["code"]}, completed_attempt)
  end

  defp dependency_terminal_error(%Job{} = dep) do
    %{
      "code" => "dependency_failed",
      "message" => "dependency job #{dep.id} reached #{dep.status}",
      "details" => %{"dependency_job_id" => dep.id, "dependency_status" => dep.status}
    }
  end

  defp current_attempt!(%Job{id: job_id, current_attempt: number}) do
    Repo.one!(from(a in JobAttempt, where: a.job_id == ^job_id and a.number == ^number))
  end

  defp update_job!(%Job{} = job, attrs) do
    case job |> Job.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp update_attempt!(%JobAttempt{} = attempt, attrs) do
    case attempt |> JobAttempt.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp record_event!(%Job{} = job, status, data, attempt \\ nil) do
    now = DateTime.utc_now(:microsecond)
    sequence = next_sequence(job.id)

    attrs = %{
      job_id: job.id,
      attempt: job.current_attempt,
      sequence: sequence,
      type: "job.#{status}",
      status: status,
      step: status,
      outcome: status,
      correlation_id: job.correlation_id,
      occurred_at: now,
      recorded_at: now,
      data: data,
      schema_version: 1
    }

    case %JobEvent{} |> JobEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} when status in @terminal ->
        attempt = attempt || current_attempt!(job)
        :ok = Omashiki.Jobs.Webhooks.enqueue_for_event!(job, attempt, event)
        event

      {:ok, event} ->
        event

      {:error, changeset} ->
        Repo.rollback({:persistence, changeset})
    end
  end

  defp next_sequence(job_id) do
    case Repo.one(from(e in JobEvent, where: e.job_id == ^job_id, select: max(e.sequence))) do
      nil -> 1
      max -> max + 1
    end
  end

  defp enqueue!(%Job{} = job) do
    case Oban.insert(
           DispatchWorker.new(%{"job_id" => job.id},
             priority: job.priority,
             scheduled_at: job.queued_at
           )
         ) do
      {:ok, _oban_job} -> :ok
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end
end
