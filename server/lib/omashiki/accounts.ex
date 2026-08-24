defmodule Omashiki.Accounts do
  @moduledoc """
  User identity context: registration (signup-once), authentication, and
  password updates.

  Multi-user is a non-goal for v1, but the schema and queries are already
  user-scoped. The single switch that enforces single-user is
  `register_user/1`, which refuses to insert when `count/0 > 0`.
  """

  import Ecto.Query
  alias Omashiki.Repo
  alias Omashiki.Accounts.User

  @doc """
  Registers a new user. Refuses with `{:error, :registration_closed}` when
  any user already exists.

  Wrapped in a serializable transaction so two concurrent first-boot
  signups cannot both succeed.
  """
  def register_user(attrs) do
    Repo.transaction(
      fn ->
        case Repo.aggregate(User, :count, :id) do
          0 ->
            %User{}
            |> User.registration_changeset(attrs)
            |> Repo.insert()
            |> case do
              {:ok, user} -> user
              {:error, changeset} -> Repo.rollback(changeset)
            end

          _ ->
            Repo.rollback(:registration_closed)
        end
      end,
      isolation: :serializable
    )
  rescue
    # Postgres aborts one of two concurrent serializable transactions with
    # SQLSTATE 40001. Surface that as :registration_closed so the caller
    # sees the same outcome whether they lost the race to count == 0 or to
    # the unique index.
    Postgrex.Error -> {:error, :registration_closed}
    DBConnection.ConnectionError -> {:error, :registration_closed}
  end

  @doc """
  Looks up a user by id. Returns `nil` when missing.
  """
  def get_user(nil), do: nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  @doc """
  Looks up a user by email or username. The match is case-insensitive thanks
  to the `citext` columns.
  """
  def get_user_by_identifier(nil), do: nil
  def get_user_by_identifier(""), do: nil

  def get_user_by_identifier(identifier) when is_binary(identifier) do
    Repo.one(from u in User, where: u.email == ^identifier or u.username == ^identifier)
  end

  @doc """
  Authenticates a user by `(email_or_username, password)`. Always runs
  Argon2 verification (even when the user does not exist) to keep timing
  attack surface flat.

  Returns `{:ok, user}` or `{:error, :invalid_credentials}`.
  """
  def authenticate(identifier, password)
      when is_binary(identifier) and is_binary(password) do
    user = get_user_by_identifier(identifier)

    cond do
      user && Argon2.verify_pass(password, user.password_hash) ->
        {:ok, user}

      user ->
        {:error, :invalid_credentials}

      true ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def authenticate(_, _), do: {:error, :invalid_credentials}

  @doc """
  Replaces the password for a user. Returns `{:ok, user}` or
  `{:error, changeset}`.
  """
  def update_password(%User{} = user, new_password) do
    user
    |> User.password_changeset(%{password: new_password})
    |> Repo.update()
  end

  @doc """
  Returns a profile changeset for the form (no DB write). Used by the
  `/settings/profile` LiveView for `phx-change` validation.
  """
  def change_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc """
  Updates the email + username of a user. Validates format / length and
  surfaces unique-constraint violations as changeset errors.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Verifies the user's current password and, on match, persists the new
  one. Returns one of:

    * `{:ok, user}` on success
    * `{:error, :invalid_credentials}` when `current` does not match the
      stored hash
    * `{:error, %Ecto.Changeset{}}` when the new password fails validation
  """
  def change_password(%User{} = user, current, new)
      when is_binary(current) and is_binary(new) do
    if Argon2.verify_pass(current, user.password_hash) do
      update_password(user, new)
    else
      Argon2.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  def change_password(_, _, _), do: {:error, :invalid_credentials}

  @doc """
  Total user count. Used by `register_user/1` and the signup controller to
  enforce signup-once.
  """
  def count, do: Repo.aggregate(User, :count, :id)

  @doc """
  Returns the sole registered operator when exactly one user exists.
  Used by `auth_mode: :none` on loopback to impersonate the local owner.
  """
  def sole_user do
    case Repo.all(from(u in User, limit: 2)) do
      [user] -> user
      _ -> nil
    end
  end

  @doc """
  The user to act as when authentication is off.

  Returns the first registered operator. When the database has none — a fresh
  clone with `auth.enabled = false` — one is created, because the screens
  assume a `current_user` and would crash on `nil`. The password is random and
  unusable: with auth off nothing checks it, and if auth is turned back on the
  operator resets it rather than finding a blank account waiting.
  """
  def local_owner do
    Repo.transaction(fn ->
      case Repo.all(from(u in User, order_by: [asc: u.inserted_at], limit: 1)) do
        [user] ->
          user

        [] ->
          %User{}
          |> User.registration_changeset(%{
            username: "local",
            email: "local@omashiki.local",
            password: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64()
          })
          |> Repo.insert()
          |> case do
            {:ok, user} -> user
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, user} -> user
      {:error, _} -> nil
    end
  end

  @doc """
  Signup is open only when no users exist yet.
  """
  def signup_open?, do: count() == 0
end
