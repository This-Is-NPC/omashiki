defmodule Omashiki.ApiTokens.Audit do
  @moduledoc "Append-only audit of token mutations. Failures never fail the caller."

  import Ecto.Query

  require Logger

  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.{AuditEvent, Token}
  alias Omashiki.Repo

  @doc "Record an audit event. A missing token is a no-op."
  def record(token, action, opts \\ [])

  def record(nil, _action, _opts), do: :ok

  def record(%Token{id: token_id}, action, opts) when is_binary(action) do
    attrs = %{
      api_token_id: token_id,
      action: action,
      job_id: Keyword.get(opts, :job_id),
      ip: Keyword.get(opts, :ip),
      request_id: Keyword.get(opts, :request_id),
      occurred_at: DateTime.utc_now(:microsecond)
    }

    case %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("[ApiTokens.Audit] insert failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[ApiTokens.Audit] insert raised: #{Exception.message(error)}")
      :ok
  end

  @doc "Recent audit events for the operator's tokens."
  def recent_for_user(%User{id: user_id}, limit \\ 8) do
    from(e in AuditEvent,
      join: t in Token,
      on: t.id == e.api_token_id,
      where: t.user_id == ^user_id,
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: ^limit,
      preload: [:api_token]
    )
    |> Repo.all()
  end

  @doc "Delete audit rows older than the configured retention."
  def prune(older_than) do
    {count, _} =
      from(e in AuditEvent, where: e.occurred_at < ^older_than)
      |> Repo.delete_all()

    {:ok, count}
  end
end
