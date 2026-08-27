defmodule Omashiki.Jobs.JobDependency do
  @moduledoc "Directed dependency edge between two jobs owned by the same user."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @on_failure_values ~w(cancel block proceed)

  schema "job_dependencies" do
    field :on_failure, :string, default: "cancel"

    belongs_to :job, Omashiki.Jobs.Job
    belongs_to :depends_on_job, Omashiki.Jobs.Job
    belongs_to :user, Omashiki.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:job_id, :depends_on_job_id, :user_id, :on_failure])
    |> validate_required([:job_id, :depends_on_job_id, :user_id, :on_failure])
    |> validate_inclusion(:on_failure, @on_failure_values)
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:depends_on_job_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:job_id, name: :job_dependencies_job_owner_fkey)
    |> foreign_key_constraint(:depends_on_job_id, name: :job_dependencies_dep_owner_fkey)
    |> check_constraint(:on_failure, name: :job_dependencies_on_failure_check)
    |> check_constraint(:depends_on_job_id, name: :job_dependencies_not_self)
    |> unique_constraint([:job_id, :depends_on_job_id])
  end
end
