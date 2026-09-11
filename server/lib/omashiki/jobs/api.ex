defmodule Omashiki.Jobs.Api do
  @moduledoc "Owner-aware reads for the public queue API."

  import Ecto.Query

  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.Token
  alias Omashiki.Jobs.{Job, JobAttempt, JobDependency, JobEvent, JobStep, WebhookDelivery}
  alias Omashiki.Repo
  alias Omashiki.UsageLedger.Entry

  @statuses ~w(blocked queued provisioning running succeeded failed cancelled)
  @terminal_statuses ~w(succeeded failed cancelled)
  @default_limit 50
  @max_limit 100
  @view_max_limit 500
  @view_sorts [:inserted_at, :started_at, :finished_at, :priority]

  def statuses, do: @statuses
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc "List jobs visible to the exact submitting token or local operator."
  def list(actor, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    status = Keyword.get(opts, :status)

    cond do
      not is_integer(limit) or limit < 1 or limit > @max_limit ->
        {:error, :invalid_limit}

      not is_nil(status) and status not in @statuses ->
        {:error, :invalid_status}

      true ->
        query =
          from(j in Job,
            order_by: [desc: j.inserted_at, desc: j.id],
            limit: ^limit
          )

        query = if is_nil(status), do: query, else: where(query, [j], j.status == ^status)
        query = apply_actor_scope(query, actor)

        {:ok, Repo.all(query)}
    end
  end

  @doc "Fetch one job when the actor owns its token or is the local operator."
  def get(job_id, actor) do
    with {:ok, id} <- cast_id(job_id),
         %Job{} = job <- Repo.get(Job, id),
         :ok <- authorize(job, actor) do
      {:ok, job}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def current_attempt(%Job{} = job) do
    Repo.one(
      from(a in JobAttempt, where: a.job_id == ^job.id and a.number == ^job.current_attempt)
    )
  end

  @doc "Return the operator's jobs, including only queue-operation fields."
  def list_for_operator(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_limit)

    from(j in Job,
      where: j.user_id == ^user.id,
      order_by: [desc: j.inserted_at, desc: j.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Return the operator's jobs for a display-only task view. Each row carries the
  job, its current attempt, and that attempt's steps. Reads only.

  `:filter` accepts `:status`, `:environment`, `:repository`, `:priority`, and
  `:worker` value lists, and `:since`, a `DateTime` compared with submission.
  `:sort` is `{field, :asc | :desc}` over submission, start, finish, or priority.
  """
  def list_for_view(%User{} = user, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@view_max_limit)
    {sort_field, direction} = Keyword.get(opts, :sort, {:inserted_at, :desc})

    rows =
      from(j in Job,
        as: :job,
        left_join: a in JobAttempt,
        as: :attempt,
        on: a.job_id == j.id and a.number == j.current_attempt,
        where: j.user_id == ^user.id,
        limit: ^limit,
        select: {j, a}
      )
      |> filter_view(Keyword.get(opts, :filter, %{}))
      |> order_view(sort_field, direction)
      |> Repo.all()

    attempt_ids = for {_job, %JobAttempt{id: id}} <- rows, do: id

    steps =
      from(s in JobStep,
        where: s.attempt_id in ^attempt_ids,
        order_by: [asc: s.attempt_id, asc: s.sequence]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.attempt_id)

    Enum.map(rows, fn {job, attempt} ->
      %{job: job, attempt: attempt, steps: attempt_steps(steps, attempt)}
    end)
  end

  defp filter_view(query, filter) do
    Enum.reduce(filter, query, fn
      {:status, values}, query -> where(query, [job: j], j.status in ^values)
      {:environment, values}, query -> where(query, [job: j], j.environment in ^values)
      {:repository, values}, query -> where(query, [job: j], j.repository in ^values)
      {:priority, values}, query -> where(query, [job: j], j.priority in ^values)
      {:worker, values}, query -> where(query, [attempt: a], a.machine_id in ^values)
      {:since, %DateTime{} = since}, query -> where(query, [job: j], j.inserted_at >= ^since)
      {:attempt_ids, ids}, query -> where(query, [attempt: a], a.id in ^ids)
    end)
  end

  defp order_view(query, field, :asc) when field in @view_sorts,
    do: order_by(query, [job: j], asc_nulls_last: field(j, ^field), asc: j.id)

  defp order_view(query, field, :desc) when field in @view_sorts,
    do: order_by(query, [job: j], desc_nulls_last: field(j, ^field), desc: j.id)

  defp attempt_steps(_steps, nil), do: []
  defp attempt_steps(steps, %JobAttempt{id: id}), do: Map.get(steps, id, [])

  @doc "Map attempt ids to job ids, only for jobs `actor` may read."
  def job_ids_for_attempts(actor, attempt_ids) when is_list(attempt_ids) do
    ids = for id <- attempt_ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid

    if ids == [] do
      %{}
    else
      from(j in Job,
        join: a in JobAttempt,
        on: a.job_id == j.id,
        where: a.id in ^ids,
        select: {a.id, j.id}
      )
      |> apply_actor_scope(actor)
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc "Return all durable observations needed by the operator job detail."
  def detail(job_id, %User{} = user) do
    with {:ok, job} <- get(job_id, user) do
      attempts =
        from(a in JobAttempt, where: a.job_id == ^job.id, order_by: [asc: a.number])
        |> Repo.all()

      attempt_ids = Enum.map(attempts, & &1.id)

      steps =
        from(s in JobStep,
          where: s.attempt_id in ^attempt_ids,
          order_by: [asc: s.attempt_id, asc: s.sequence]
        )
        |> Repo.all()

      events =
        from(e in JobEvent,
          where: e.job_id == ^job.id,
          order_by: [asc: e.sequence]
        )
        |> Repo.all()

      usage =
        from(e in Entry,
          where: e.job_id == ^job.id,
          order_by: [asc: e.turn, asc: e.occurred_at]
        )
        |> Repo.all()

      webhooks =
        from(d in WebhookDelivery,
          join: e in JobEvent,
          on: e.event_id == d.event_id,
          where: e.job_id == ^job.id,
          order_by: [desc: d.inserted_at]
        )
        |> Repo.all()

      {:ok,
       %{
         job: job,
         dependencies: dependencies(job),
         attempts: attempts,
         steps: steps,
         events: events,
         usage: usage,
         webhooks: webhooks
       }}
    end
  end

  @doc "Return recent terminal events belonging to the operator."
  def recent_terminal_events(%User{} = user, limit \\ 8) do
    terminal_statuses = @terminal_statuses

    from(e in JobEvent,
      join: j in Job,
      on: j.id == e.job_id,
      where: j.user_id == ^user.id and e.status in ^terminal_statuses,
      order_by: [desc: e.occurred_at, desc: e.sequence],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Return failed or dead webhook deliveries for the operator."
  def recent_webhook_failures(%User{} = user, limit \\ 8) do
    failure_statuses = ["failed", "dead"]

    from(d in WebhookDelivery,
      join: e in JobEvent,
      on: e.event_id == d.event_id,
      join: j in Job,
      on: j.id == e.job_id,
      where: j.user_id == ^user.id and d.status in ^failure_statuses,
      order_by: [desc: d.updated_at, desc: d.id],
      limit: ^limit,
      select: %{
        id: d.id,
        job_id: e.job_id,
        status: d.status,
        attempts: d.attempts,
        last_error: d.last_error,
        updated_at: d.updated_at
      }
    )
    |> Repo.all()
  end

  defp dependencies(%Job{id: job_id}) do
    from(d in JobDependency,
      where: d.job_id == ^job_id,
      select: %{depends_on_job_id: d.depends_on_job_id, on_failure: d.on_failure}
    )
    |> Repo.all()
  end

  def authorize(%Job{} = job, %Token{id: token_id, user_id: user_id}) do
    if job.user_id == user_id and job.api_token_id == token_id,
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize(%Job{user_id: user_id}, %User{id: user_id}), do: :ok
  def authorize(_, _), do: {:error, :forbidden}

  defp apply_actor_scope(query, %Token{id: token_id, user_id: user_id}) do
    where(query, [j], j.user_id == ^user_id and j.api_token_id == ^token_id)
  end

  defp apply_actor_scope(query, %User{id: user_id}), do: where(query, [j], j.user_id == ^user_id)
  defp apply_actor_scope(query, _), do: where(query, [j], false)

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
