defmodule Omashiki.Jobs.JobStep do
  @moduledoc "Ordered observable step within one job attempt."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(pending running succeeded failed cancelled skipped)

  schema "job_steps" do
    field :sequence, :integer
    field :key, :string
    field :kind, :string
    field :status, :string, default: "pending"
    field :input, :map
    field :output, :map
    field :error, :map
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :attempt, Omashiki.Jobs.JobAttempt
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :attempt_id,
      :sequence,
      :key,
      :kind,
      :status,
      :input,
      :output,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:attempt_id, :sequence, :key, :kind, :status])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:attempt_id, :sequence])
    |> unique_constraint([:attempt_id, :key])
    |> foreign_key_constraint(:attempt_id)
  end
end
