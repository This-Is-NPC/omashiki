defmodule Omashiki.Repo.Migrations.KeyExecutionCapacityByNode do
  use Ecto.Migration

  # One capacity row per node, keyed by `node_id`, replacing the singleton that
  # `CHECK (id = 1)` pinned.
  #
  # This is a re-key, not a new concurrency design. `UPDATE ... WHERE active <
  # capacity` is still a single-row atomic compare-and-swap and still guards
  # exactly one row; only *which* row it guards moves, from "the row" to "this
  # machine's row". Without that move the second node to boot overwrites the
  # first node's budget in `sync_capacity/0`, and both then admit against a
  # number neither of them declared.
  #
  # The surviving row keeps its counter under `node_id = 'local'` rather than
  # being dropped. It is real state — the budget of the one machine that was
  # running before this migration — and its `active` count belongs to attempts
  # still in flight. Those attempts carry `job_attempts.node_id IS NULL`,
  # because they were claimed before that column was written, so
  # `release_capacity_if_reserved!` releases them against `'local'`: the row
  # they were counted in, and the only row that can honestly hold them.
  #
  # A machine that calls itself something else gets its own row at boot, where
  # `sync_capacity/0` reconciles it from `[limits].max_concurrent_containers`.
  # `'local'` then drains to zero as its in-flight attempts finish and is the
  # operator's to delete.
  def up do
    alter table(:execution_capacity) do
      add :node_id, :text
    end

    execute "UPDATE execution_capacity SET node_id = 'local' WHERE node_id IS NULL"

    # Dropping `id` takes `execution_capacity_pkey` and the `CHECK (id = 1)`
    # that named the singleton with it.
    alter table(:execution_capacity) do
      remove :id
      modify :node_id, :text, null: false
    end

    execute "ALTER TABLE execution_capacity ADD PRIMARY KEY (node_id)"
  end

  # Lossy by construction, like every rollback on this table — run it with the
  # queue drained.
  #
  # `capacity` collapses to the largest node's budget, not the sum: one machine
  # must not inherit the whole cluster's ceiling. `active` carries every
  # outstanding reservation so nothing is released against a counter that never
  # counted it, clamped to that budget so `active <= capacity` still holds.
  # Clamping is self-healing rather than corrupting: `release_capacity!` is a
  # `WHERE active > 0` decrement, so the surplus no-ops at zero and the counter
  # converges as the in-flight attempts finish.
  #
  # Which node a reservation belonged to is not recoverable afterwards, which
  # is the other half of why this wants a drained queue.
  def down do
    execute "ALTER TABLE execution_capacity DROP CONSTRAINT execution_capacity_pkey"

    alter table(:execution_capacity) do
      add :id, :integer
      remove :node_id
    end

    execute """
    WITH collapsed AS (
      DELETE FROM execution_capacity RETURNING capacity, active
    ), totals AS (
      SELECT COALESCE(MAX(capacity), 8) AS capacity, COALESCE(SUM(active), 0) AS active
      FROM collapsed
    )
    INSERT INTO execution_capacity (id, capacity, active, inserted_at, updated_at)
    SELECT 1, capacity, LEAST(active, capacity), NOW(), NOW() FROM totals
    """

    alter table(:execution_capacity) do
      modify :id, :integer, null: false
    end

    execute "ALTER TABLE execution_capacity ADD PRIMARY KEY (id)"
    create constraint(:execution_capacity, :execution_capacity_id_check, check: "id = 1")
  end
end
