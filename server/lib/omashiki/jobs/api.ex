defmodule Omashiki.Jobs.Api do
  @moduledoc "Owner-aware reads for the public queue API, Home, and System."

  import Ecto.Query

  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.Token
  alias Omashiki.Jobs.{Job, JobAttempt, JobDependency, JobEvent, JobStep, Statuses}
  alias Omashiki.Repo
  alias Omashiki.UsageLedger.Entry
  alias Omashiki.Jobs.WebhookDelivery

  @default_page_size 50
  @max_page_size 500
  @view_sorts [:inserted_at, :started_at, :finished_at, :priority]

  def statuses, do: Statuses.all()
  def default_page_size, do: @default_page_size

  @doc """
  List jobs visible to the actor.

  Options:

    * `:filter` — `:status`, `:environment`, `:repository`, `:priority`,
      `:worker` (lists or a single value), `:correlation_id`, `:since`,
      and `:attempt_ids`
    * `:cursor` — opaque `inserted_at` + `id` cursor
    * `:page_size` — page length, default #{@default_page_size}, max #{@max_page_size}
    * `:sort` — `{field, :asc | :desc}` for Home; API uses insertion order
    * `:as` — `:jobs` (default) or `:rows` (job + current attempt + steps)
  """
  def list(actor, opts \\ []) do
    page_size = opts |> Keyword.get(:page_size, @default_page_size) |> max(1) |> min(@max_page_size)
    as = Keyword.get(opts, :as, :jobs)
    filter = opts |> Keyword.get(:filter, %{}) |> normalize_filter()
    {sort_field, direction} = Keyword.get(opts, :sort, {:inserted_at, :desc})

    with :ok <- validate_filter(filter),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      query =
        from(j in Job,
          as: :job,
          left_join: a in JobAttempt,
          as: :attempt,
          on: a.job_id == j.id and a.number == j.current_attempt
        )
        |> apply_named_actor_scope(actor)
        |> filter_view(filter)
        |> apply_cursor(cursor, direction)
        |> order_view(sort_field, direction)
        |> limit(^(page_size + 1))

      case as do
        :rows ->
          rows = query |> select([job: j, attempt: a], {j, a}) |> Repo.all()
          {page, rest} = split_page(rows, page_size)

          {:ok,
           %{
             entries: with_steps(page),
             next_cursor: next_cursor_from_rows(rest, page)
           }}

        _ ->
          jobs = query |> select([job: j], j) |> Repo.all()
          {page, rest} = split_page(jobs, page_size)

          {:ok,
           %{
             entries: page,
             next_cursor: next_cursor(rest, page)
           }}
      end
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
    terminal = Statuses.terminal()

    from(e in JobEvent,
      join: j in Job,
      on: j.id == e.job_id,
      where: j.user_id == ^user.id and e.status in ^terminal,
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

  defp apply_named_actor_scope(query, %Token{id: token_id, user_id: user_id}) do
    where(query, [job: j], j.user_id == ^user_id and j.api_token_id == ^token_id)
  end

  defp apply_named_actor_scope(query, %User{id: user_id}),
    do: where(query, [job: j], j.user_id == ^user_id)

  defp apply_named_actor_scope(query, _), do: where(query, [job: j], false)

  defp normalize_filter(filter) when is_map(filter) do
    Enum.reduce(filter, %{}, fn
      {key, value}, acc
      when key in [:status, :environment, :repository, :priority, :worker] and is_binary(value) ->
        Map.put(acc, key, [value])

      {key, value}, acc
      when key in [:status, :environment, :repository, :priority, :worker] and is_list(value) ->
        Map.put(acc, key, value)

      {:correlation_id, value}, acc when is_binary(value) and value != "" ->
        Map.put(acc, :correlation_id, value)

      {:since, %DateTime{} = since}, acc ->
        Map.put(acc, :since, since)

      {:attempt_ids, ids}, acc when is_list(ids) ->
        Map.put(acc, :attempt_ids, ids)

      _, acc ->
        acc
    end)
  end

  defp validate_filter(filter) do
    case Map.get(filter, :status) do
      nil ->
        :ok

      values when is_list(values) ->
        if Enum.all?(values, &(&1 in Statuses.all())), do: :ok, else: {:error, :invalid_status}

      _ ->
        {:error, :invalid_status}
    end
  end

  defp filter_view(query, filter) do
    Enum.reduce(filter, query, fn
      {:status, values}, query -> where(query, [job: j], j.status in ^values)
      {:environment, values}, query -> where(query, [job: j], j.environment in ^values)
      {:repository, values}, query -> where(query, [job: j], j.repository in ^values)
      {:priority, values}, query -> where(query, [job: j], j.priority in ^values)
      {:worker, values}, query -> where(query, [attempt: a], a.machine_id in ^values)
      {:correlation_id, value}, query -> where(query, [job: j], j.correlation_id == ^value)
      {:since, %DateTime{} = since}, query -> where(query, [job: j], j.inserted_at >= ^since)
      {:attempt_ids, ids}, query -> where(query, [attempt: a], a.id in ^ids)
    end)
  end

  defp apply_cursor(query, nil, _direction), do: query

  defp apply_cursor(query, {at, id}, :desc) do
    where(query, [job: j], j.inserted_at < ^at or (j.inserted_at == ^at and j.id < ^id))
  end

  defp apply_cursor(query, {at, id}, :asc) do
    where(query, [job: j], j.inserted_at > ^at or (j.inserted_at == ^at and j.id > ^id))
  end

  defp order_view(query, field, :asc) when field in @view_sorts,
    do: order_by(query, [job: j], asc_nulls_last: field(j, ^field), asc: j.id)

  defp order_view(query, field, :desc) when field in @view_sorts,
    do: order_by(query, [job: j], desc_nulls_last: field(j, ^field), desc: j.id)

  defp with_steps(rows) do
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

  defp attempt_steps(_steps, nil), do: []
  defp attempt_steps(steps, %JobAttempt{id: id}), do: Map.get(steps, id, [])

  defp split_page(items, page_size) do
    {Enum.take(items, page_size), Enum.drop(items, page_size)}
  end

  defp next_cursor([], _page), do: nil
  defp next_cursor(_rest, page), do: page |> List.last() |> encode_cursor()

  defp next_cursor_from_rows([], _page), do: nil

  defp next_cursor_from_rows(_rest, page) do
    case List.last(page) do
      {job, _} -> encode_cursor(job)
      %{job: job} -> encode_cursor(job)
    end
  end

  defp encode_cursor(nil), do: nil

  defp encode_cursor(%{inserted_at: at, id: id}) do
    %{"t" => DateTime.to_iso8601(at), "id" => id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"t" => t, "id" => id}} <- Jason.decode(json),
         {:ok, at, _} <- DateTime.from_iso8601(t),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {at, uuid}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_), do: {:error, :invalid_cursor}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
