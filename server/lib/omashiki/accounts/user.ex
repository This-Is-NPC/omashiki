defmodule Omashiki.Accounts.User do
  @moduledoc """
  A human operator. The first row owns the running app; subsequent rows
  are blocked at the controller layer (signup-once) but the schema and
  query plumbing already support multi-user.

  `password_hash` is an Argon2id digest; `password` is a virtual field that
  only exists on the changeset. Both are scrubbed from `Inspect/1` and
  Phoenix logs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Inspect, except: [:password_hash, :password]}

  schema "users" do
    field :email, :string
    field :username, :string
    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true
    timestamps(type: :utc_datetime_usec)
  end

  @username_regex ~r/^[a-zA-Z0-9_-]+$/
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc """
  Registration changeset — validates and hashes `password` into
  `password_hash`. Used by `Accounts.register_user/1`.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :password])
    |> validate_required([:email, :username, :password])
    |> validate_format(:email, @email_regex, message: "Must be a valid email.")
    |> validate_length(:email, max: 255)
    |> validate_format(:username, @username_regex,
      message: "Letters, numbers, hyphens, underscores. 2–64 chars."
    )
    |> validate_length(:username, min: 2, max: 64)
    |> validate_length(:password,
      min: 8,
      max: 200,
      message: "Must be at least 8 characters."
    )
    |> unique_constraint(:email, message: "That email is already in use.")
    |> unique_constraint(:username, message: "That username is taken.")
    |> hash_password()
  end

  @doc """
  Password-only changeset used by the password reset task and
  `Accounts.change_password/3`.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password,
      min: 8,
      max: 200,
      message: "Must be at least 8 characters."
    )
    |> hash_password()
  end

  @doc """
  Profile changeset — covers email + username only. Used by
  `Accounts.update_user/2` to power the `/settings/profile` form.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username])
    |> validate_required([:email, :username])
    |> validate_format(:email, @email_regex, message: "Must be a valid email.")
    |> validate_length(:email, max: 255)
    |> validate_format(:username, @username_regex,
      message: "Letters, numbers, hyphens, underscores. 2–64 chars."
    )
    |> validate_length(:username, min: 2, max: 64)
    |> unique_constraint(:email, message: "That email is already in use.")
    |> unique_constraint(:username, message: "That username is taken.")
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
