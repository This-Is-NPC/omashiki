defmodule Omashiki.Jobs.JobAttempt do
  @moduledoc "One numbered execution attempt for a durable job."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(blocked queued provisioning running succeeded failed cancelled)

  schema "job_attempts" do
    field :number, :integer
    field :status, :string
    field :oban_job_id, :integer
    field :runner_id, :string
    field :machine_id, :string
    field :lease_token, :string
    field :lease_expires_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :capacity_reserved, :boolean, default: false
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :branch, :string
    field :base_sha, :string
    field :head_sha, :string
    field :worktree_clean, :boolean
    field :result, :map
    field :error, :map

    belongs_to :job, Omashiki.Jobs.Job
    has_many :steps, Omashiki.Jobs.JobStep, foreign_key: :attempt_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :job_id,
      :number,
      :status,
      :oban_job_id,
      :runner_id,
      :machine_id,
      :lease_token,
      :lease_expires_at,
      :heartbeat_at,
      :claimed_at,
      :capacity_reserved,
      :started_at,
      :finished_at,
      :branch,
      :base_sha,
      :head_sha,
      :worktree_clean,
      :result,
      :error
    ])
    |> validate_required([:job_id, :number, :status])
    |> validate_number(:number, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:job_id, :number])
    |> unique_constraint(:oban_job_id)
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:oban_job_id)
    |> check_constraint(:base_sha, name: :job_attempts_base_sha_check)
    |> check_constraint(:head_sha, name: :job_attempts_head_sha_check)
    |> check_constraint(:status, name: :job_attempts_terminal_shape)
  end
end
