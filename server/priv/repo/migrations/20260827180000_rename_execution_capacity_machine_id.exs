defmodule Omashiki.Repo.Migrations.RenameExecutionCapacityMachineId do
  use Ecto.Migration

  # Vocabulary cut: the capacity row is keyed by the same machine name
  # `job_attempts.machine_id` already records. Historical migrations that
  # introduced `node_id` stay as written.
  def up do
    rename table(:execution_capacity), :node_id, to: :machine_id
  end

  def down do
    rename table(:execution_capacity), :machine_id, to: :node_id
  end
end
