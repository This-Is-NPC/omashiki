defmodule Omashiki.Jobs.JsonValue do
  @moduledoc false
  @behaviour Ecto.Type

  def type, do: :map

  def cast(value), do: if(json_value?(value), do: {:ok, value}, else: :error)
  def dump(value), do: if(json_value?(value), do: {:ok, value}, else: :error)
  def load(value), do: {:ok, value}
  def embed_as(_format), do: :self
  def equal?(left, right), do: left == right

  defp json_value?(nil), do: true
  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_boolean(value) or is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: value == value
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_), do: false
end

defmodule Omashiki.Jobs.Job do
  @moduledoc "Durable admitted job and its immutable execution snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(blocked queued provisioning running succeeded failed cancelled)
  @admission_fields [
    :user_id,
    :api_token_id,
    :schema_version,
    :idempotency_key,
    :correlation_id,
    :repository,
    :environment,
    :payload,
    :payload_hash,
    :admitted_repository,
    :admitted_repository_digest,
    :admitted_environment,
    :admitted_environment_digest,
    :admitted_plugin_digest,
    :admitted_plugin,
    :registry_digest,
    :queue,
    :priority
  ]
  @state_fields [
    :status,
    :current_attempt,
    :queued_at,
    :started_at,
    :finished_at,
    :terminal_result,
    :terminal_error,
    :dependency_artifacts
  ]

  schema "jobs" do
    field :schema_version, :integer, default: 1
    field :idempotency_key, :string
    field :correlation_id, :string
    field :repository, :string
    field :environment, :string
    field :payload, Omashiki.Jobs.JsonValue
    field :payload_hash, :string
    field :admitted_repository, :map
    field :admitted_repository_digest, :string
    field :admitted_environment, :map
    field :admitted_environment_digest, :string
    field :admitted_plugin, :map
    field :admitted_plugin_digest, :string
    field :registry_digest, :string
    field :queue, :string, default: "default"
    field :priority, :integer, default: 0
    field :status, :string
    field :current_attempt, :integer, default: 1
    field :queued_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :terminal_result, :map
    field :terminal_error, :map
    field :dependency_artifacts, Omashiki.Jobs.JsonValue

    belongs_to :user, Omashiki.Accounts.User
    belongs_to :api_token, Omashiki.ApiTokens.Token
    has_many :dependencies, Omashiki.Jobs.JobDependency, foreign_key: :job_id
    has_many :attempts, Omashiki.Jobs.JobAttempt
    has_many :events, Omashiki.Jobs.JobEvent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    fields =
      if job.__meta__.state == :built, do: @admission_fields ++ @state_fields, else: @state_fields

    job
    |> cast(attrs, fields)
    |> validate_required([
      :user_id,
      :idempotency_key,
      :correlation_id,
      :environment,
      :payload,
      :payload_hash,
      :admitted_environment,
      :admitted_environment_digest,
      :admitted_plugin_digest,
      :admitted_plugin,
      :registry_digest,
      :queue,
      :priority,
      :status,
      :current_attempt
    ])
    |> validate_repository_shape()
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
    |> validate_number(:current_attempt, greater_than: 0)
    |> unique_constraint([:user_id, :idempotency_key])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:api_token_id)
    |> foreign_key_constraint(:api_token_id, name: :jobs_api_token_owner_fkey)
    |> check_constraint(:status, name: :jobs_terminal_shape)
  end

  defp validate_repository_shape(changeset) do
    repository = get_field(changeset, :repository)
    admitted_repository = get_field(changeset, :admitted_repository)
    admitted_repository_digest = get_field(changeset, :admitted_repository_digest)

    cond do
      is_nil(repository) and is_nil(admitted_repository) and is_nil(admitted_repository_digest) ->
        changeset

      is_binary(repository) and is_map(admitted_repository) and
          is_binary(admitted_repository_digest) ->
        changeset

      true ->
        add_error(
          changeset,
          :repository,
          "repository snapshot must be present or absent together"
        )
    end
  end
end
