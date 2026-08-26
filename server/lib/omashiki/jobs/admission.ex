defmodule Omashiki.Jobs.Admission do
  @moduledoc "Transactional admission of authenticated single jobs and batches."

  import Ecto.Query

  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.Token
  alias Omashiki.Config
  alias Omashiki.Config.Rollout
  alias Omashiki.Jobs.{DispatchWorker, Job, JobAttempt, JobEvent}
  alias Omashiki.Jobs.Contract.V1
  alias Omashiki.Repo

  @default_queue "default"
  @max_batch_size 100

  def max_batch_size, do: @max_batch_size

  @doc "Admit one root job for an active, persisted API token."
  def admit(%Token{} = token, attrs) when is_map(attrs) do
    with :ok <- admission_open(),
         {:ok, request} <- validate_single(attrs),
         {:ok, user_id} <- authorize(token),
         nil <- find_existing(user_id, token.id, request["idempotency_key"]),
         {:ok, resolved} <- resolve(request) do
      insert_single(user_id, token.id, request, resolved)
    else
      %Job{} = existing -> {:ok, existing}
      {:error, reason} -> {:error, reason}
      {:conflict, _existing} -> {:error, :idempotency_conflict}
    end
  end

  def admit(_, _), do: {:error, :unauthorized}

  @doc "Admit an ordered, atomically persisted batch of jobs."
  def admit_batch(%Token{} = token, attrs) when is_map(attrs) do
    with :ok <- admission_open(),
         {:ok, request} <- validate_batch(attrs),
         {:ok, user_id} <- authorize(token),
         {:ok, items} <- prepare_batch(user_id, token.id, request),
         result <- insert_batch(user_id, token.id, request["correlation_id"], items) do
      result
    end
  end

  def admit_batch(_, _), do: {:error, :unauthorized}

  # A `drain_all` rollout is waiting for the fleet to empty. Admitting here
  # would keep it from ever emptying, so the door closes at the front rather
  # than the work queueing up behind the swap.
  defp admission_open do
    if Rollout.admission_open?(), do: :ok, else: {:error, :admission_paused}
  end

  defp validate_single(attrs) do
    case V1.validate_single(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, errors} -> {:error, {:validation, errors}}
    end
  end

  defp validate_batch(attrs) do
    case V1.validate_batch(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, errors} -> {:error, {:validation, errors}}
    end
  end

  defp authorize(%Token{id: id}) when is_binary(id) do
    case Repo.get(Token, id) do
      %Token{user_id: user_id} = persisted when is_binary(user_id) ->
        if Token.status(persisted) == :active and not is_nil(Repo.get(User, user_id)) do
          {:ok, user_id}
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp authorize(_), do: {:error, :unauthorized}

  defp find_existing(user_id, token_id, idempotency_key) do
    case Repo.get_by(Job, user_id: user_id, idempotency_key: idempotency_key) do
      nil -> nil
      %Job{api_token_id: ^token_id} = job -> job
      %Job{} = job -> {:conflict, job}
    end
  end

  defp resolve(request) do
    case Config.resolve_job(request["repo"], request["environment"]) do
      {:ok, resolved} -> {:ok, snapshot_context(resolved)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_context(%Config.ResolvedJob{} = resolved) do
    repository = snapshot_value(resolved.repository)
    environment = snapshot_value(resolved.environment)

    %{
      repository: repository,
      environment: environment,
      repository_digest: digest(repository),
      environment_digest: digest(environment),
      registry_digest: resolved.digest
    }
  end

  defp snapshot_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> snapshot_value()
  end

  defp snapshot_value(%{} = map) do
    map
    |> Enum.reject(fn {key, _value} -> key in [:api_key, "api_key"] end)
    |> Map.new(fn {key, value} -> {to_string(key), snapshot_value(value)} end)
  end

  defp snapshot_value(list) when is_list(list), do: Enum.map(list, &snapshot_value/1)
  defp snapshot_value(nil), do: nil
  defp snapshot_value(value) when is_boolean(value), do: value
  defp snapshot_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp snapshot_value(value), do: value

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp insert_single(user_id, token_id, request, resolved) do
    result =
      Repo.transaction(fn ->
        attrs = job_attrs(user_id, token_id, request, resolved, nil)

        case insert_job(attrs) do
          {:ok, job} ->
            persist_effects(job)
            job

          {:error, changeset} ->
            if unique_idempotency_error?(changeset),
              do: Repo.rollback(:duplicate_idempotency),
              else: Repo.rollback({:persistence, changeset})
        end
      end)

    case result do
      {:ok, job} ->
        {:ok, job}

      {:error, :duplicate_idempotency} ->
        fetch_after_race(user_id, token_id, request["idempotency_key"])

      {:error, {:persistence, changeset}} ->
        {:error, changeset}
    end
  end

  defp prepare_batch(user_id, token_id, %{"jobs" => jobs}) do
    if length(jobs) > @max_batch_size do
      {:error, {:limit, "batch_too_large", length(jobs), @max_batch_size}}
    else
      prepare_batch_items(user_id, token_id, jobs)
    end
  end

  defp prepare_batch_items(user_id, token_id, jobs) do
    existing =
      from(j in Job,
        where:
          j.user_id == ^user_id and j.idempotency_key in ^Enum.map(jobs, & &1["idempotency_key"])
      )
      |> Repo.all()
      |> Map.new(&{&1.idempotency_key, &1})

    Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, acc} ->
      case Map.get(existing, job["idempotency_key"]) do
        %Job{api_token_id: ^token_id} = admitted ->
          {:cont, {:ok, [%{request: job, existing: admitted} | acc]}}

        %Job{} ->
          {:halt, {:error, :idempotency_conflict}}

        nil ->
          case resolve(job) do
            {:ok, resolved} ->
              {:cont, {:ok, [%{request: job, resolved: resolved} | acc]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp insert_batch(user_id, token_id, correlation_id, items) do
    result =
      Repo.transaction(fn ->
        refs =
          items
          |> Enum.filter(&Map.has_key?(&1, :existing))
          |> Map.new(fn %{request: request, existing: job} -> {request["ref"], job} end)

        insert_batch_items(user_id, token_id, correlation_id, items, refs)
      end)

    case result do
      {:ok, jobs_by_ref} ->
        {:ok, Enum.map(items, &Map.fetch!(jobs_by_ref, &1.request["ref"]))}

      {:error, :duplicate_idempotency} ->
        retry_batch(user_id, token_id, correlation_id, items)

      {:error, {:persistence, changeset}} ->
        {:error, changeset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_batch_items(_user_id, _token_id, _correlation_id, [], jobs_by_ref),
    do: jobs_by_ref

  defp insert_batch_items(user_id, token_id, correlation_id, items, jobs_by_ref) do
    case Enum.find_index(items, &ready_for_insert?(&1, jobs_by_ref)) do
      nil ->
        Repo.rollback(:batch_parent_resolution)

      index ->
        {item, remaining} = List.pop_at(items, index)

        case Map.get(item, :existing) do
          %Job{} = existing ->
            insert_batch_items(
              user_id,
              token_id,
              correlation_id,
              remaining,
              Map.put(jobs_by_ref, item.request["ref"], existing)
            )

          nil ->
            parent_id = parent_id(item.request, jobs_by_ref)
            request = Map.put(item.request, "correlation_id", correlation_id)
            attrs = job_attrs(user_id, token_id, request, item.resolved, parent_id)

            case insert_job(attrs) do
              {:ok, job} ->
                persist_effects(job)

                insert_batch_items(
                  user_id,
                  token_id,
                  correlation_id,
                  remaining,
                  Map.put(jobs_by_ref, item.request["ref"], job)
                )

              {:error, changeset} ->
                if unique_idempotency_error?(changeset),
                  do: Repo.rollback(:duplicate_idempotency),
                  else: Repo.rollback({:persistence, changeset})
            end
        end
    end
  end

  defp ready_for_insert?(%{request: %{"parent_ref" => parent_ref}}, jobs_by_ref),
    do: Map.has_key?(jobs_by_ref, parent_ref)

  defp ready_for_insert?(%{request: request}, _jobs_by_ref),
    do: not Map.has_key?(request, "parent_ref")

  defp parent_id(%{"parent_ref" => parent_ref}, jobs_by_ref), do: jobs_by_ref[parent_ref].id
  defp parent_id(_, _), do: nil

  defp job_attrs(user_id, token_id, request, resolved, parent_id) do
    status = if is_nil(parent_id), do: "queued", else: "blocked"
    now = DateTime.utc_now(:microsecond)

    %{
      user_id: user_id,
      api_token_id: token_id,
      parent_job_id: parent_id,
      schema_version: 1,
      idempotency_key: request["idempotency_key"],
      correlation_id: request["correlation_id"],
      repository: request["repo"],
      environment: request["environment"],
      payload: request["payload"],
      payload_hash: digest_payload(request["payload"]),
      repository_snapshot: resolved.repository,
      repository_digest: resolved.repository_digest,
      environment_snapshot: resolved.environment,
      environment_digest: resolved.environment_digest,
      registry_digest: resolved.registry_digest,
      queue: @default_queue,
      priority: request["priority"],
      status: status,
      current_attempt: 1,
      queued_at: if(status == "queued", do: now)
    }
  end

  defp digest_payload(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp insert_job(attrs) do
    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert()
  end

  defp persist_effects(%Job{} = job) do
    status = job.status
    now = DateTime.utc_now(:microsecond)

    insert_attempt!(job, status)
    insert_event!(job, status, now)

    if status == "queued" do
      case Oban.insert(
             DispatchWorker.new(
               %{"job_id" => job.id},
               priority: job.priority,
               scheduled_at: job.queued_at
             )
           ) do
        {:ok, _oban_job} -> :ok
        {:error, changeset} -> Repo.rollback({:persistence, changeset})
      end
    end
  end

  defp insert_attempt!(job, status) do
    case %JobAttempt{}
         |> JobAttempt.changeset(%{job_id: job.id, number: 1, status: status})
         |> Repo.insert() do
      {:ok, _attempt} -> :ok
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp insert_event!(job, status, now) do
    data = if status == "blocked", do: %{"parent_job_id" => job.parent_job_id}, else: %{}

    case %JobEvent{}
         |> JobEvent.changeset(%{
           job_id: job.id,
           attempt: 1,
           sequence: 1,
           type: "job.#{status}",
           status: status,
           step: status,
           outcome: status,
           correlation_id: job.correlation_id,
           occurred_at: now,
           recorded_at: now,
           data: data,
           schema_version: 1
         })
         |> Repo.insert() do
      {:ok, _event} -> :ok
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp fetch_after_race(user_id, token_id, idempotency_key) do
    case find_existing(user_id, token_id, idempotency_key) do
      %Job{} = job -> {:ok, job}
      {:conflict, _job} -> {:error, :idempotency_conflict}
      nil -> {:error, :idempotency_race}
    end
  end

  defp retry_batch(user_id, token_id, correlation_id, items) do
    case Enum.reduce_while(items, {:ok, []}, fn %{request: request} = item, {:ok, acc} ->
           case find_existing(user_id, token_id, request["idempotency_key"]) do
             %Job{} = job -> {:cont, {:ok, [%{request: request, existing: job} | acc]}}
             {:conflict, _job} -> {:halt, {:error, :idempotency_conflict}}
             nil -> {:cont, {:ok, [item | acc]}}
           end
         end) do
      {:ok, refreshed} -> insert_batch(user_id, token_id, correlation_id, Enum.reverse(refreshed))
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_idempotency_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] == "jobs_user_id_idempotency_key_index"

      _ ->
        false
    end)
  end
end
