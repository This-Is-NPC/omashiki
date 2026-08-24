defmodule Omashiki.Jobs.WebhookDelivery do
  @moduledoc "Durable at-least-once delivery state for one terminal job event."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(pending delivering delivered failed dead)

  schema "webhook_deliveries" do
    field :destination, :string
    field :idempotency_key, :binary_id
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :last_response_status, :integer
    field :last_error, :map
    field :payload, :map
    field :payload_hash, :string
    field :signing_key_id, :string
    field :signing_secret_ciphertext, :string, redact: true

    belongs_to :event, Omashiki.Jobs.JobEvent,
      references: :event_id,
      foreign_key: :event_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :event_id,
      :destination,
      :idempotency_key,
      :status,
      :attempts,
      :next_attempt_at,
      :delivered_at,
      :last_response_status,
      :last_error,
      :payload,
      :payload_hash,
      :signing_key_id,
      :signing_secret_ciphertext
    ])
    |> validate_required([
      :event_id,
      :destination,
      :idempotency_key,
      :status,
      :attempts,
      :next_attempt_at,
      :payload,
      :payload_hash
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> unique_constraint([:event_id, :destination])
    |> unique_constraint([:destination, :idempotency_key])
    |> foreign_key_constraint(:event_id)
    |> check_constraint(:status, name: :webhook_deliveries_delivery_shape)
  end
end
