defmodule Omashiki.Repo.Migrations.AddNodeIdToJobAttempts do
  use Ecto.Migration

  # Which machine ran this attempt. `runner_id` already looks like an answer and
  # is not one: it carries `"oban:<id>"`, which identifies the dispatch job, not
  # the host. Two attempts on two machines can share a runner id shape and tell
  # you nothing about where the container actually ran, and per-node capacity
  # needs a column it can join on.
  #
  # Nullable on purpose. The column is written when an attempt is claimed, so a
  # `blocked` or `queued` attempt has no node yet, exactly as it has no
  # `runner_id` yet. Rows that predate this migration keep NULL: there is no
  # honest backfill, because the machine that ran them was never recorded.
  # Reversible — `down` drops the column.
  def change do
    alter table(:job_attempts) do
      add :node_id, :text
    end
  end
end
