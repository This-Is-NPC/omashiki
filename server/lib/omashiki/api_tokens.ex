defmodule Omashiki.ApiTokens do
  @moduledoc """
  Context for owner-bound API tokens.
  """

  import Ecto.Query

  require Logger

  alias Omashiki.Repo
  alias Omashiki.ApiTokens.{Hash, Token}
  alias Omashiki.Accounts.User
  alias Omashiki.Jobs.Webhooks

  @doc """
  Creates a token for `user`. Returns `{:ok, token, plaintext}`.

  """
  def create_for_user(%User{} = user, attrs) do
    plaintext = Hash.generate_plaintext()
    token_hash = Hash.hmac(plaintext)

    expires_at =
      attrs
      |> Map.get(:expires_at, Map.get(attrs, "expires_at"))
      |> normalize_datetime()

    create_attrs = %{
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      expires_at: expires_at,
      token_hash: token_hash,
      user_id: user.id
    }

    %Token{}
    |> Token.create_changeset(create_attrs)
    |> Repo.insert()
    |> case do
      {:ok, token} -> {:ok, token, plaintext}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(""), do: nil

  defp normalize_datetime(%DateTime{} = dt),
    do: DateTime.truncate(dt, :microsecond)

  defp normalize_datetime(%Date{} = date) do
    {:ok, dt} = DateTime.new(date, ~T[23:59:59], "Etc/UTC")
    DateTime.truncate(dt, :microsecond)
  end

  defp normalize_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        DateTime.truncate(dt, :microsecond)

      _ ->
        case Date.from_iso8601(s) do
          {:ok, date} -> normalize_datetime(date)
          _ -> nil
        end
    end
  end

  def list_for_user(%User{} = user) do
    Token
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_for_user!(%User{} = user, id) do
    Token
    |> where(user_id: ^user.id, id: ^id)
    |> Repo.one!()
  end

  def revoke(%User{} = user, id) when is_binary(id) do
    case Repo.get_by(Token, id: id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      token ->
        Repo.update(Token.revoke_changeset(token))
    end
  end

  @doc "Configure the token-owned terminal webhook without exposing secret material."
  def configure_webhook(%Token{} = token, attrs) when is_map(attrs),
    do: Webhooks.configure(token, attrs)

  def find_active_by_plaintext(plaintext) when is_binary(plaintext) and plaintext != "" do
    hash = Hash.hmac(plaintext)
    now = DateTime.utc_now(:microsecond)

    Token
    |> where(token_hash: ^hash)
    |> where([t], is_nil(t.revoked_at))
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> preload(:user)
    |> Repo.one()
    |> case do
      nil -> :error
      token -> {:ok, token}
    end
  end

  def find_active_by_plaintext(_), do: :error

  # Coarse on purpose. Every authenticated request used to issue an
  # unconditional UPDATE on this one row, so N concurrent requests carrying the
  # same token serialized on its row lock — each holding a pool connection while
  # it waited. Under a few hundred requests per second that convoy drains the
  # pool and the API starts answering 500. `last_used_at` only ever feeds a
  # "last seen" column in the tokens screen, so one write per @use_resolution is
  # all the precision it needs.
  #
  # Measured, 400 concurrent callers sharing one token, 24-connection pool
  # (`bench/record_use_bench.exs`, task #2793):
  #
  #   * the guard is what kills the convoy. Postgres does NOT take the row lock
  #     to evaluate a predicate that does not match — a competing writer holding
  #     the row uncommitted delays the guarded no-op by 0.1s and the
  #     unguarded UPDATE by the full 2s. Unconditional p50 was ~48x the guarded
  #     p50 for exactly that reason.
  #   * the guard does not make the statement free. It is still one pool
  #     checkout and one round trip on the request path, and running it inline
  #     costs the caller an order of magnitude more than handing it off.
  #
  # So both halves stay: the guard, and keeping the write off the caller. The
  # hand-off is supervised and bounded rather than a bare `Task.start` — under
  # saturation `record_use` sheds the write instead of spawning without limit,
  # which is the right trade for a 60s-resolution "last seen" column.
  @use_resolution 60

  @doc """
  Records that `token` was just presented, at `@use_resolution` granularity.

  Always returns `:ok`: failing to note a last-seen timestamp must never fail
  the request that carried the token. Failures are logged, not raised and not
  dropped on the floor.
  """
  def record_use(%Token{id: id}) do
    run_use_write(fn -> touch_last_used(id) end)
    :ok
  end

  # `:async` in every environment that serves requests. `config/test.exs` picks
  # `:inline` so the write runs in the caller — which under `Ecto.Adapters.SQL.
  # Sandbox` is the process that owns the connection. A detached task is not,
  # and checking out from it is what produced the "owner exited" /
  # `DBConnection.ConnectionError` noise in the suite log.
  defp run_use_write(fun) do
    case Application.get_env(:omashiki, :api_token_use_write, :async) do
      :inline ->
        fun.()

      :async ->
        case Task.Supervisor.start_child(Omashiki.ApiTokens.TaskSupervisor, fun) do
          {:ok, _pid} ->
            :ok

          other ->
            Logger.warning("[ApiTokens] dropped a last_used_at write: #{inspect(other)}")
            :ok
        end
    end
  end

  defp touch_last_used(id) do
    now = DateTime.utc_now(:microsecond)
    cutoff = DateTime.add(now, -@use_resolution, :second)

    Token
    |> where([t], t.id == ^id)
    |> where([t], is_nil(t.last_used_at) or t.last_used_at < ^cutoff)
    |> Repo.update_all(set: [last_used_at: now])
  rescue
    error ->
      log_failed_write(id, Exception.message(error))
  catch
    # A pool checkout that loses its queue slot exits rather than raising, so
    # `rescue` alone would let it through — and inline, that exit would take the
    # caller with it. `record_use/1` promises `:ok` either way.
    :exit, reason ->
      log_failed_write(id, inspect(reason))
  end

  defp log_failed_write(id, detail) do
    Logger.warning("[ApiTokens] last_used_at write failed for #{id}: #{detail}")
    {0, nil}
  end

  def accessible?(%User{}, _resource), do: true
  def accessible?(%Token{}, _resource), do: true
  def accessible?(_, _), do: false

  def can_write_global?(%User{}), do: true
  def can_write_global?(%Token{}), do: true
  def can_write_global?(_), do: false
end
