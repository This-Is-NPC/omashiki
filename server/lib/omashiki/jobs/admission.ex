defmodule Omashiki.Jobs.Admission do
  @moduledoc "Transactional admission of authenticated single jobs and batches."

  import Ecto.Query

  alias Omashiki.Config.Environment
  alias Omashiki.Jobs.TaskBranch
  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.Token
  alias Omashiki.Config
  alias Omashiki.Config.Rollout

  alias Omashiki.Jobs.{
    Dependencies,
    DispatchWorker,
    Job,
    JobAttempt,
    JobDependency,
    JobEvent,
    Statuses
  }

  alias Omashiki.Repo
  alias Omashiki.Tx

  @default_queue "default"
  @max_batch_size 100

  def max_batch_size, do: @max_batch_size
  def max_payload_bytes, do: Statuses.max_payload_bytes()

  @doc "Admit one root job for an active, persisted API token."
  def admit(%Token{} = token, attrs) when is_map(attrs) do
    case admit_once(token, attrs) do
      {:ok, _origin, job} -> {:ok, job}
      other -> other
    end
  end

  def admit(_, _), do: {:error, :unauthorized}

  @doc """
  Admit one job and say whether the row was created or replayed.

  Idempotent retries return `{:ok, :existing, job}` so callers do not guess
  from `inserted_at`.
  """
  def admit_once(%Token{} = token, attrs) when is_map(attrs) do
    with :ok <- admission_open(),
         {:ok, request} <- validate_single(attrs),
         :ok <- environment_allowed(token, request["environment"]),
         {:ok, user_id} <- authorize(token),
         nil <- find_existing(user_id, token.id, request["idempotency_key"]),
         {:ok, resolved} <- resolve(request) do
      user_id |> insert_single(token, request, resolved) |> notify_admitted()
    else
      %Job{} = existing -> {:ok, :existing, existing}
      {:error, reason} -> {:error, reason}
      {:conflict, _existing} -> {:error, :idempotency_conflict}
    end
  end

  def admit_once(_, _), do: {:error, :unauthorized}

  @doc "Admit an ordered, atomically persisted batch of jobs."
  def admit_batch(%Token{} = token, attrs) when is_map(attrs) do
    case admit_batch_once(token, attrs) do
      {:ok, tagged} -> {:ok, Enum.map(tagged, fn {_origin, job} -> job end)}
      other -> other
    end
  end

  def admit_batch(_, _), do: {:error, :unauthorized}

  @doc "Admit a batch and tag each job as `:created` or `:existing`."
  def admit_batch_once(%Token{} = token, attrs) when is_map(attrs) do
    with :ok <- admission_open(),
         {:ok, request} <- validate_batch(attrs),
         :ok <- batch_environments_allowed(token, request["jobs"]),
         {:ok, user_id} <- authorize(token),
         {:ok, items} <- prepare_batch(user_id, token.id, request),
         {:ok, tagged} <- insert_batch(token, request["correlation_id"], items) do
      notify_admitted({:ok, Enum.map(tagged, fn {_origin, job} -> job end)})
      {:ok, tagged}
    end
  end

  def admit_batch_once(_, _), do: {:error, :unauthorized}

  # Admission inserts rows directly rather than through `Jobs`, so it announces
  # new jobs itself, after the transaction commits.
  defp notify_admitted({:ok, :created, %Job{id: id} = job}) do
    Omashiki.Jobs.broadcast_updated(id)
    {:ok, :created, job}
  end

  defp notify_admitted({:ok, :existing, job}), do: {:ok, :existing, job}

  defp notify_admitted({:ok, jobs} = result) when is_list(jobs) do
    Enum.each(jobs, &Omashiki.Jobs.broadcast_updated(&1.id))
    result
  end

  defp notify_admitted(result), do: result

  # A `drain_all` rollout is waiting for the fleet to empty. Admitting here
  # would keep it from ever emptying, so the door closes at the front rather
  # than the work queueing up behind the swap.
  defp admission_open do
    if Rollout.admission_open?(), do: :ok, else: {:error, :admission_paused}
  end

  defp validate_single(attrs) when is_map(attrs) do
    with :ok <- validate_payload_size(attrs) do
      {:ok, attrs}
    end
  end

  defp validate_single(_), do: {:error, {:validation, [%{field: "$", code: "object_required"}]}}

  defp validate_batch(attrs) when is_map(attrs) do
    jobs = Map.get(attrs, "jobs")

    with :ok <- validate_batch_jobs(jobs),
         :ok <- validate_payloads(jobs) do
      {:ok, attrs}
    end
  end

  defp validate_batch(_), do: {:error, {:validation, [%{field: "$", code: "object_required"}]}}

  defp validate_payloads(jobs) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      case validate_payload_size(job) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_payload_size(%{"payload" => payload}) do
    size = payload |> Jason.encode!() |> byte_size()

    if size > Statuses.max_payload_bytes() do
      {:error, {:validation, [%{field: "payload", code: "too_large"}]}}
    else
      :ok
    end
  end

  defp validate_payload_size(_),
    do: {:error, {:validation, [%{field: "payload", code: "required"}]}}

  defp validate_batch_jobs(jobs) when is_list(jobs) and jobs != [] do
    refs = for job <- jobs, is_map(job), do: job["ref"]
    keys = Enum.map(jobs, & &1["idempotency_key"])
    ref_set = refs |> Enum.filter(&is_binary/1) |> MapSet.new()

    errors =
      duplicate_errors(refs, "jobs.ref") ++
        duplicate_errors(keys, "jobs.idempotency_key") ++
        depends_on_errors(jobs, ref_set) ++
        batch_cycle_errors(jobs)

    if errors == [], do: :ok, else: {:error, {:validation, errors}}
  end

  defp validate_batch_jobs([]),
    do: {:error, {:validation, [%{field: "jobs", code: "must_not_be_empty"}]}}

  defp validate_batch_jobs(_),
    do: {:error, {:validation, [%{field: "jobs", code: "array_required"}]}}

  defp duplicate_errors(values, field) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn _ -> %{field: field, code: "duplicate"} end)
  end

  defp depends_on_errors(jobs, ref_set) do
    Enum.flat_map(jobs, fn job ->
      ref = Map.get(job, "ref")

      Map.get(job, "depends_on", [])
      |> Enum.flat_map(fn
        %{"ref" => dep_ref} = dep ->
          cond do
            dep_ref == ref ->
              [%{field: "jobs.depends_on", code: "self_dependency"}]

            not MapSet.member?(ref_set, dep_ref) ->
              [%{field: "jobs.depends_on", code: "unknown_ref"}]

            is_binary(Map.get(dep, "id")) ->
              [%{field: "jobs.depends_on", code: "id_or_ref_required"}]

            true ->
              []
          end

        %{"id" => _} ->
          []

        _ ->
          [%{field: "jobs.depends_on", code: "id_or_ref_required"}]
      end)
    end)
  end

  defp batch_cycle_errors(jobs) do
    graph =
      Map.new(jobs, fn job ->
        deps =
          job
          |> Map.get("depends_on", [])
          |> Enum.flat_map(fn
            %{"ref" => ref} -> [ref]
            _ -> []
          end)

        {Map.get(job, "ref"), deps}
      end)

    if Enum.any?(Map.keys(graph), &cycle_from?(&1, graph, MapSet.new())) do
      [%{field: "jobs.depends_on", code: "cycle"}]
    else
      []
    end
  end

  defp cycle_from?(ref, graph, path) do
    cond do
      is_nil(ref) -> false
      MapSet.member?(path, ref) -> true
      true -> Enum.any?(Map.get(graph, ref, []), &cycle_from?(&1, graph, MapSet.put(path, ref)))
    end
  end

  defp environment_allowed(%Token{allowed_environments: list}, env) when is_list(list) do
    if "*" in list or env in list, do: :ok, else: {:error, :environment_not_allowed}
  end

  defp environment_allowed(_, _), do: {:error, :environment_not_allowed}

  defp batch_environments_allowed(token, jobs) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      case environment_allowed(token, job["environment"]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def lock_token!(token_id) when is_binary(token_id) do
    case from(t in Token, where: t.id == ^token_id, lock: "FOR UPDATE") |> Repo.one() do
      nil -> Repo.rollback(:unauthorized)
      %Token{} = locked -> locked
    end
  end

  @doc false
  def enforce_token_active_limit!(token_id, incoming)
      when is_binary(token_id) and is_integer(incoming) and incoming >= 0 do
    locked = lock_token!(token_id)

    terminal = Statuses.terminal()

    active =
      from(j in Job,
        where: j.api_token_id == ^token_id and j.status not in ^terminal,
        select: count(j.id)
      )
      |> Repo.one()

    if active + incoming > locked.max_active_jobs do
      Repo.rollback(:max_active_jobs)
    else
      :ok
    end
  end

  defp enforce_active_limit!(%Token{id: token_id}, incoming) do
    enforce_token_active_limit!(token_id, incoming)
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
    with {:ok, %Config.ResolvedJob{} = resolved} <-
           Config.resolve_job(request["repo"], request["environment"]),
         {:ok, task_branch} <- validate_git_task_branch(request, resolved.environment) do
      {:ok, snapshot_context(resolved, task_branch, resolved.environment)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_context(%Config.ResolvedJob{} = resolved, task_branch, environment) do
    repository =
      if resolved.repository,
        do:
          snapshot_value(resolved.repository)
          |> maybe_put_task_branch(task_branch, environment),
        else: nil

    plugin = plugin_snapshot(resolved.environment)
    environment = snapshot_value(resolved.environment)

    %{
      repository: repository,
      environment: environment,
      admitted_repository_digest: if(repository, do: digest(repository), else: nil),
      admitted_environment_digest: digest(environment),
      admitted_plugin: plugin,
      admitted_plugin_digest: digest(plugin),
      registry_digest: resolved.digest
    }
  end

  defp plugin_snapshot(%{preset: %{manifest: %Omashiki.Plugin.Manifest{} = manifest}}) do
    Omashiki.Plugin.Manifest.admitted_snapshot(manifest)
  end

  defp plugin_snapshot(environment) do
    raise ArgumentError, "environment has no plugin manifest: #{inspect(environment)}"
  end

  defp snapshot_value(%Omashiki.Plugin.Manifest{} = manifest),
    do: Omashiki.Plugin.Manifest.snapshot(manifest)

  defp snapshot_value(%Omashiki.Plugin.Preset{} = preset) do
    preset
    |> Map.from_struct()
    |> Map.delete(:adapter)
    |> Map.update!(:launch_plan, &snapshot_value/1)
    |> snapshot_value()
  end

  defp snapshot_value(%Omashiki.Harness.LaunchPlan{} = launch_plan) do
    launch_plan
    |> Map.from_struct()
    |> snapshot_value()
  end

  defp snapshot_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> snapshot_value()
  end

  defp snapshot_value(%{} = map) do
    map
    |> Enum.reject(fn {key, _value} ->
      key in [
        :api_key,
        "api_key",
        :private_key,
        "private_key",
        :ssh_key,
        "ssh_key",
        :ssh_key_passphrase,
        "ssh_key_passphrase"
      ]
    end)
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

  defp insert_single(user_id, %Token{} = token, request, resolved) do
    result =
      Tx.run(fn ->
        enforce_active_limit!(token, 1)

        case resolve_depends_on(user_id, request, %{}, nil) do
          {:ok, edges} ->
            attrs = job_attrs(user_id, token.id, request, resolved, edges)

            case insert_job(attrs) do
              {:ok, job} ->
                insert_dependencies!(job, edges)
                persist_effects(job, edges)
                job

              {:error, changeset} ->
                if unique_idempotency_error?(changeset),
                  do: Repo.rollback(:duplicate_idempotency),
                  else: Repo.rollback({:persistence, changeset})
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, job} ->
        {:ok, :created, job}

      {:error, :duplicate_idempotency} ->
        case fetch_after_race(user_id, token.id, request["idempotency_key"]) do
          {:ok, job} -> {:ok, :existing, job}
          error -> error
        end

      {:error, {:persistence, changeset}} ->
        {:error, changeset}

      {:error, reason} ->
        {:error, reason}
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

  defp insert_batch(%Token{} = token, correlation_id, items) do
    result =
      Tx.run(fn ->
        incoming = Enum.count(items, &is_nil(Map.get(&1, :existing)))
        enforce_active_limit!(token, incoming)

        refs =
          items
          |> Enum.filter(&Map.has_key?(&1, :existing))
          |> Map.new(fn %{request: request, existing: job} -> {request["ref"], job} end)

        insert_batch_items(token.user_id, token.id, correlation_id, items, refs)
      end)

    case result do
      {:ok, jobs_by_ref} ->
        {:ok,
         Enum.map(items, fn item ->
           job = Map.fetch!(jobs_by_ref, item.request["ref"])
           origin = if(Map.has_key?(item, :existing), do: :existing, else: :created)
           {origin, job}
         end)}

      {:error, :duplicate_idempotency} ->
        retry_batch(token, correlation_id, items)

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
            request = Map.put(item.request, "correlation_id", correlation_id)

            case resolve_depends_on(user_id, request, jobs_by_ref, item.request["ref"]) do
              {:ok, edges} ->
                attrs = job_attrs(user_id, token_id, request, item.resolved, edges)

                case insert_job(attrs) do
                  {:ok, job} ->
                    insert_dependencies!(job, edges)
                    persist_effects(job, edges)

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

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
    end
  end

  defp ready_for_insert?(%{request: request}, jobs_by_ref) do
    depends_on = Map.get(request, "depends_on", [])

    Enum.all?(depends_on, fn dep ->
      cond do
        is_map(dep) and is_binary(Map.get(dep, "ref")) ->
          Map.has_key?(jobs_by_ref, dep["ref"])

        is_map(dep) and is_binary(Map.get(dep, "id")) ->
          true

        true ->
          false
      end
    end)
  end

  defp resolve_depends_on(user_id, request, jobs_by_ref, self_ref) do
    depends_on = Map.get(request, "depends_on", [])

    with {:ok, edges} <- build_depends_on_edges(depends_on, jobs_by_ref),
         :ok <- check_self_dependency(depends_on, self_ref),
         :ok <- check_dependencies_exist(user_id, edges) do
      {:ok, edges}
    end
  end

  defp build_depends_on_edges(depends_on, jobs_by_ref) do
    depends_on
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case build_depends_on_edge(dep, jobs_by_ref) do
        {:ok, edge} -> {:cont, {:ok, [edge | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, edges} -> {:ok, Enum.reverse(edges)}
      err -> err
    end
  end

  defp build_depends_on_edge(dep, jobs_by_ref) do
    cond do
      is_map(dep) and is_binary(Map.get(dep, "ref")) ->
        case Map.get(jobs_by_ref, dep["ref"]) do
          %{id: id} -> {:ok, {id, Map.get(dep, "on_failure", "cancel")}}
          nil -> {:error, :unknown_dependency}
        end

      is_map(dep) and is_binary(Map.get(dep, "id")) ->
        {:ok, {dep["id"], Map.get(dep, "on_failure", "cancel")}}

      true ->
        {:error, {:validation, [%{field: "depends_on", code: "id_or_ref_required"}]}}
    end
  end

  defp check_self_dependency(depends_on, self_ref) do
    if not is_nil(self_ref) and
         Enum.any?(depends_on, fn dep -> Map.get(dep, "ref") == self_ref end) do
      {:error, :self_dependency}
    else
      :ok
    end
  end

  defp check_dependencies_exist(_user_id, []), do: :ok

  defp check_dependencies_exist(user_id, edges) do
    ids = Enum.map(edges, fn {id, _} -> id end)

    dep_jobs =
      from(j in Job, where: j.id in ^ids and j.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    if Enum.any?(edges, fn {id, _} -> not Map.has_key?(dep_jobs, id) end) do
      {:error, :unknown_dependency}
    else
      :ok
    end
  end

  defp initial_status([]), do: "queued"

  defp initial_status(edges) do
    ids = Enum.map(edges, fn {id, _} -> id end)

    deps =
      from(j in Job, where: j.id in ^ids)
      |> Repo.all()

    if Enum.all?(deps, &(&1.status == "succeeded")), do: "queued", else: "blocked"
  end

  defp job_attrs(user_id, token_id, request, resolved, edges) do
    status = initial_status(edges)
    now = DateTime.utc_now(:microsecond)
    repository = maybe_put_git_base(resolved.repository, request, edges, resolved.environment)

    %{
      user_id: user_id,
      api_token_id: token_id,
      idempotency_key: request["idempotency_key"],
      correlation_id: request["correlation_id"],
      repository: request["repo"],
      environment: request["environment"],
      payload: request["payload"],
      payload_hash: digest_payload(request["payload"]),
      dependency_artifacts: queued_dependency_artifacts(status, edges),
      admitted_repository: repository,
      admitted_repository_digest: resolved.admitted_repository_digest,
      admitted_environment: resolved.environment,
      admitted_environment_digest: resolved.admitted_environment_digest,
      admitted_plugin: resolved.admitted_plugin,
      admitted_plugin_digest: resolved.admitted_plugin_digest,
      registry_digest: resolved.registry_digest,
      queue: @default_queue,
      priority: request["priority"],
      status: status,
      current_attempt: 1,
      queued_at: if(status == "queued", do: now)
    }
  end

  defp queued_dependency_artifacts("queued", [_ | _] = edges),
    do: Dependencies.artifacts_for(edges)

  defp queued_dependency_artifacts(_, _), do: nil

  defp maybe_put_git_base(nil, _request, _edges, _environment), do: nil

  defp maybe_put_git_base(repository, request, edges, environment) when is_map(repository) do
    cond do
      is_binary(Map.get(request, "base")) and Map.get(request, "base") != "" ->
        Map.put(repository, "base", request["base"])

      edges != [] and git_sink?(environment) ->
        Map.put(repository, "base", "dependency")

      true ->
        repository
    end
  end

  defp git_sink?(environment) when is_map(environment) do
    (Map.get(environment, "sink") || Map.get(environment, :sink)) == "git"
  end

  defp git_sink?(_), do: false

  defp insert_dependencies!(%Job{} = job, edges) do
    Enum.each(edges, fn {depends_on_job_id, on_failure} ->
      case %JobDependency{}
           |> JobDependency.changeset(%{
             job_id: job.id,
             depends_on_job_id: depends_on_job_id,
             user_id: job.user_id,
             on_failure: on_failure
           })
           |> Repo.insert() do
        {:ok, _} -> :ok
        {:error, changeset} -> Repo.rollback({:persistence, changeset})
      end
    end)
  end

  defp blocked_event_data([]), do: %{}

  defp blocked_event_data(edges) do
    %{"depends_on" => Enum.map(edges, fn {id, _} -> id end)}
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

  defp persist_effects(%Job{} = job, edges) do
    status = job.status
    now = DateTime.utc_now(:microsecond)

    insert_attempt!(job, status)
    insert_event!(job, status, now, edges)

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

  defp insert_event!(job, status, now, edges) do
    data = if status == "blocked", do: blocked_event_data(edges), else: %{}

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
           data: data
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

  defp retry_batch(%Token{} = token, correlation_id, items) do
    case Enum.reduce_while(items, {:ok, []}, fn %{request: request} = item, {:ok, acc} ->
           case find_existing(token.user_id, token.id, request["idempotency_key"]) do
             %Job{} = job -> {:cont, {:ok, [%{request: request, existing: job} | acc]}}
             {:conflict, _job} -> {:halt, {:error, :idempotency_conflict}}
             nil -> {:cont, {:ok, [item | acc]}}
           end
         end) do
      {:ok, refreshed} -> insert_batch(token, correlation_id, Enum.reverse(refreshed))
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_git_task_branch(request, %Environment{sink: "git"}) do
    case TaskBranch.resolve(request["payload"]) do
      {:ok, task_branch} ->
        {:ok, task_branch}

      {:error, :task_branch_required} ->
        {:error, :task_branch_required}

      {:error, reason} ->
        {:error, {:validation, [task_branch_validation_error(reason)]}}
    end
  end

  defp validate_git_task_branch(_request, %Environment{sink: sink})
       when sink in ["files", "none"],
       do: {:ok, nil}

  defp maybe_put_task_branch(repository, task_branch, %Environment{sink: "git"})
       when is_map(repository) and is_binary(task_branch) do
    Map.put(repository, "task_branch", task_branch)
  end

  defp maybe_put_task_branch(repository, _task_branch, %Environment{sink: "git"})
       when is_map(repository),
       do: repository

  defp maybe_put_task_branch(repository, _task_branch, _environment), do: repository

  defp task_branch_validation_error(:invalid_branch),
    do: %{field: "payload.branch", code: "invalid_branch"}

  defp task_branch_validation_error(:invalid_title),
    do: %{field: "payload.title", code: "invalid_title"}

  defp task_branch_validation_error(:invalid_title_slug),
    do: %{field: "payload.title", code: "invalid_title_slug"}

  defp task_branch_validation_error(reason),
    do: %{field: "payload", code: Atom.to_string(reason)}

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
