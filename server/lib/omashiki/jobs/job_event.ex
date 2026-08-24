defmodule Omashiki.Jobs.JobEvent do
  @moduledoc "Append-only sequenced observation event for one job."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:event_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "job_events" do
    field :attempt, :integer
    field :sequence, :integer
    field :type, :string
    field :status, :string
    field :step, :string
    field :outcome, :string
    field :correlation_id, :string
    field :occurred_at, :utc_datetime_usec
    field :recorded_at, :utc_datetime_usec
    field :data, :map, default: %{}
    field :schema_version, :integer, default: 1

    belongs_to :job, Omashiki.Jobs.Job
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :job_id,
      :attempt,
      :sequence,
      :type,
      :status,
      :step,
      :outcome,
      :correlation_id,
      :occurred_at,
      :recorded_at,
      :data,
      :schema_version
    ])
    |> validate_required([
      :job_id,
      :attempt,
      :sequence,
      :type,
      :status,
      :occurred_at,
      :recorded_at,
      :data,
      :schema_version
    ])
    |> validate_number(:attempt, greater_than: 0)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(
      :outcome,
      ~w(blocked queued provisioning running succeeded failed cancelled)
    )
    |> validate_inclusion(
      :step,
      ~w(blocked queued provisioning running succeeded failed cancelled)
    )
    |> validate_length(:correlation_id, min: 1, max: 255)
    |> unique_constraint([:job_id, :sequence])
    |> foreign_key_constraint(:job_id)
    |> check_constraint(:type, name: :job_events_type_status_check)
  end
end
