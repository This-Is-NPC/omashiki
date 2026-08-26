defmodule Omashiki.ApiTokens do
  @moduledoc """
  Context for owner-bound API tokens.
  """

  import Ecto.Query

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
  # all the precision it needs, and the guard makes the no-op case skip the lock
  # entirely.
  @use_resolution 60

  def record_use(%Token{id: id}) do
    Task.start(fn ->
      now = DateTime.utc_now(:microsecond)
      cutoff = DateTime.add(now, -@use_resolution, :second)

      Token
      |> where([t], t.id == ^id)
      |> where([t], is_nil(t.last_used_at) or t.last_used_at < ^cutoff)
      |> Repo.update_all(set: [last_used_at: now])
    end)

    :ok
  end

  def accessible?(%User{}, _resource), do: true
  def accessible?(%Token{}, _resource), do: true
  def accessible?(_, _), do: false

  def can_write_global?(%User{}), do: true
  def can_write_global?(%Token{}), do: true
  def can_write_global?(_), do: false
end
