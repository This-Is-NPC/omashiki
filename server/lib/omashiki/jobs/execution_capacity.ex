defmodule Omashiki.Jobs.ExecutionCapacity do
  @moduledoc """
  One row per execution machine: that machine's container budget and the slots it
  currently holds.

  Keyed by `machine_id`, which is the name from `Config.current_machine/0` and the
  same value `job_attempts.machine_id` records. Each row serializes its own machine's
  budget and nothing else, so one machine filling up neither blocks nor inflates
  another's, and a machine that never boots simply has no row.

  The row is created and reconciled by `Jobs.sync_capacity/0` at boot; nothing
  else inserts it.
  """

  use Ecto.Schema

  @primary_key {:machine_id, :string, autogenerate: false}

  schema "execution_capacity" do
    field :capacity, :integer
    field :active, :integer
    timestamps(type: :utc_datetime_usec)
  end
end
