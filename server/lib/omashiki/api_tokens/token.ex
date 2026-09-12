defmodule Omashiki.ApiTokens.Token do
  @moduledoc """
  An API token belongs to a user. The plaintext is shown ONCE on
  creation; only the hex-encoded HMAC-SHA256 digest (in `:token_hash`)
  is persisted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @allowed_scopes ~w(read submit cancel)

  @derive {Inspect,
           except: [
             :token_hash,
             :webhook_secret_ciphertext,
             :webhook_previous_secret_ciphertext
           ]}

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :scopes, {:array, :string}
    field :allowed_environments, {:array, :string}
    field :max_active_jobs, :integer
    field :webhook_destination, :string
    field :webhook_secret_ciphertext, :string, redact: true
    field :webhook_previous_secret_ciphertext, :string, redact: true
    field :webhook_key_id, :string
    field :webhook_previous_key_id, :string

    belongs_to :user, Omashiki.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def allowed_scopes, do: @allowed_scopes

  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [
      :name,
      :token_hash,
      :expires_at,
      :user_id,
      :scopes,
      :allowed_environments,
      :max_active_jobs
    ])
    |> validate_required([
      :name,
      :token_hash,
      :user_id,
      :expires_at,
      :scopes,
      :allowed_environments,
      :max_active_jobs
    ])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_scopes()
    |> validate_allowed_environments()
    |> validate_number(:max_active_jobs, greater_than: 0)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end

  def revoke_changeset(token) do
    change(token, %{revoked_at: DateTime.utc_now(:microsecond)})
  end

  def webhook_changeset(token, attrs) do
    token
    |> cast(attrs, [
      :webhook_destination,
      :webhook_secret_ciphertext,
      :webhook_previous_secret_ciphertext,
      :webhook_key_id,
      :webhook_previous_key_id
    ])
    |> validate_length(:webhook_destination, max: 2048)
    |> validate_length(:webhook_key_id, max: 80)
    |> validate_length(:webhook_previous_key_id, max: 80)
  end

  @doc """
  Returns `:active`, `:revoked`, or `:expired` for UI rendering.
  """
  def status(%__MODULE__{revoked_at: revoked_at, expires_at: expires_at}) do
    now = DateTime.utc_now()

    cond do
      not is_nil(revoked_at) -> :revoked
      DateTime.compare(now, expires_at) != :lt -> :expired
      true -> :active
    end
  end

  defp validate_scopes(changeset) do
    case get_field(changeset, :scopes) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(&1 in @allowed_scopes)) do
          changeset
        else
          add_error(changeset, :scopes, "must be read, submit, and/or cancel")
        end

      _ ->
        changeset
    end
  end

  defp validate_allowed_environments(changeset) do
    case get_field(changeset, :allowed_environments) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")) do
          changeset
        else
          add_error(changeset, :allowed_environments, "must be non-empty names or *")
        end

      _ ->
        changeset
    end
  end
end
