defmodule Omashiki.ApiTokens.AuditEvent do
  @moduledoc "Durable record of a privileged token action."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @actions ~w(submit cancel retry issue rotate revoke redeliver)

  schema "token_audit_events" do
    field :action, :string
    field :ip, :string
    field :request_id, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :api_token, Omashiki.ApiTokens.Token
    belongs_to :job, Omashiki.Jobs.Job
  end

  def actions, do: @actions

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:api_token_id, :action, :job_id, :ip, :request_id, :occurred_at])
    |> validate_required([:api_token_id, :action, :occurred_at])
    |> validate_inclusion(:action, @actions)
    |> foreign_key_constraint(:api_token_id)
    |> foreign_key_constraint(:job_id)
  end
end
