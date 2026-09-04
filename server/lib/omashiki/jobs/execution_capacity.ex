defmodule Omashiki.Jobs.ExecutionCapacity do
  @moduledoc """
  One row per manager node: this manager's in-flight attempt count and admission
  ceiling.

  Keyed by `machine_id`, which is the name from `Config.current_machine/0` and the
  same value `job_attempts.machine_id` records. Each row serializes its own
  manager's in-flight budget and nothing else, so one manager filling up neither
  blocks nor inflates another's, and a manager that never boots simply has no row.

  This is not the worker host's container budget — `Worker.Slots` owns the real
  slot semaphore after Phase 2. Embedded dispatch still uses this row as the local
  slot because `Worker.Local` does not talk to `Worker.Slots`.

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
