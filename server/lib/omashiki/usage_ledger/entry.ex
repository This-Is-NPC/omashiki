defmodule Omashiki.UsageLedger.Entry do
  @moduledoc """
  Strict append-only usage row attributed to a job attempt. `request_id` is
  unique so a retry after a crash cannot double-count.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "usage_ledger" do
    field :request_id, :string
    field :job_id, :binary_id
    field :attempt_id, :binary_id
    field :turn, :integer
    field :source, :string
    field :provider, :string
    field :model, :string
    field :input_tokens, :integer, default: 0
    # nil = adapter did not report (unknown); 0 = reported zero.
    field :cached_input_tokens, :integer
    field :output_tokens, :integer, default: 0
    field :reasoning_tokens, :integer
    field :cache_write_tokens, :integer
    field :provider_request_id, :string
    field :occurred_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :request_id,
      :job_id,
      :attempt_id,
      :turn,
      :source,
      :provider,
      :model,
      :input_tokens,
      :cached_input_tokens,
      :output_tokens,
      :reasoning_tokens,
      :cache_write_tokens,
      :provider_request_id,
      :occurred_at
    ])
    |> maybe_put_occurred_at()
    |> validate_required([:request_id, :job_id, :occurred_at])
    |> validate_number(:turn, greater_than: 0)
    |> validate_inclusion(:source, ~w(gateway engine), allow_nil: true)
    |> unique_constraint(:request_id)
    |> unique_constraint([:attempt_id, :turn])
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:attempt_id, name: :usage_ledger_attempt_job_fkey)
  end

  defp maybe_put_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now(:microsecond))
      _ -> changeset
    end
  end
end
