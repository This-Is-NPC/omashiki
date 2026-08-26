defmodule Omashiki.Repo.Migrations.RelaxExecutionCapacityCheck do
  use Ecto.Migration

  def up do
    drop constraint(:execution_capacity, :execution_capacity_values_check)

    create constraint(:execution_capacity, :execution_capacity_values_check,
             check: "capacity > 0 AND active >= 0 AND active <= capacity"
           )
  end

  # Lossy by construction — run it with the queue drained.
  #
  # `up` widens the check from `capacity = 8` to `capacity > 0`. The inverse is
  # a narrowing, and there is no lossless narrowing while `active > 8`: those
  # reservations belong to attempts a capacity-8 build cannot represent.
  #
  # So both columns are clamped unconditionally. An earlier draft guarded the
  # update with `WHERE id = 1 AND active <= 8`, which is wrong twice over: the
  # guard makes the update a silent no-op exactly when `active > 8`, and the
  # following `create constraint` then aborts the rollback transaction, so the
  # operator gets a failed migration instead of a narrowed table. The `id = 1`
  # predicate is also a dead end — the row is due to be re-keyed by `node_id`,
  # after which a hardcoded singleton id would skip every other node's row.
  #
  # Clamping `active` is self-healing rather than corrupting: `release_capacity!`
  # is a `WHERE active > 0` decrement, so the surplus releases no-op at zero and
  # the counter converges back to truth as the in-flight attempts finish. The
  # price is admitting up to `active - 8` extra containers during that window,
  # which is why this is documented as drain-first rather than made conditional.
  def down do
    drop constraint(:execution_capacity, :execution_capacity_values_check)

    execute "UPDATE execution_capacity SET capacity = 8, active = LEAST(active, 8)"

    create constraint(:execution_capacity, :execution_capacity_values_check,
             check: "capacity = 8 AND active >= 0 AND active <= capacity"
           )
  end
end
