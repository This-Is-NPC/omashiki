defmodule Omashiki.Repo.Migrations.HoldOutputForReview do
  use Ecto.Migration

  # A job whose output only failed the secret scan waits in `review` for an
  # operator. Its attempt keeps the lease token as the fence of the node that
  # holds the output, but no lease and no slot.
  def up do
    alter table(:jobs) do
      add :review, :map
    end

    replace(:jobs, :jobs_status_check, """
    status IN ('blocked','queued','provisioning','running','review','succeeded','failed','cancelled')
    """)

    replace(:jobs, :jobs_queue_timestamps, """
    (status = 'blocked' AND queued_at IS NULL) OR status = 'cancelled'
    OR (status IN ('queued','provisioning','running','review','succeeded','failed') AND queued_at IS NOT NULL)
    """)

    replace(:jobs, :jobs_start_timestamps, """
    (status IN ('blocked','queued') AND started_at IS NULL) OR status = 'cancelled'
    OR (status IN ('provisioning','running','review','succeeded','failed') AND started_at IS NOT NULL)
    """)

    replace(:jobs, :jobs_terminal_shape, """
    (status = 'succeeded' AND finished_at IS NOT NULL AND terminal_result IS NOT NULL AND terminal_error IS NULL)
    OR (status IN ('failed','cancelled') AND finished_at IS NOT NULL AND terminal_result IS NULL AND terminal_error IS NOT NULL)
    OR (status IN ('blocked','queued','provisioning','running','review') AND finished_at IS NULL AND terminal_result IS NULL AND terminal_error IS NULL)
    """)

    create constraint(:jobs, :jobs_review_shape, check: "status <> 'review' OR review IS NOT NULL")

    replace(:job_attempts, :job_attempts_status_check, """
    status IN ('blocked','queued','provisioning','running','review','succeeded','failed','cancelled')
    """)

    replace(:job_attempts, :job_attempts_start_timestamps, """
    (status IN ('blocked','queued') AND started_at IS NULL) OR status = 'cancelled'
    OR (status IN ('provisioning','running','review','succeeded','failed') AND started_at IS NOT NULL)
    """)

    replace(:job_attempts, :job_attempts_terminal_shape, """
    (status = 'succeeded' AND finished_at IS NOT NULL AND result IS NOT NULL AND error IS NULL AND (
      (branch IS NOT NULL AND base_sha IS NOT NULL AND head_sha IS NOT NULL AND worktree_clean IS TRUE)
      OR
      (branch IS NULL AND base_sha IS NULL AND head_sha IS NULL AND worktree_clean IS NULL)
    ))
    OR (status IN ('failed','cancelled') AND finished_at IS NOT NULL AND branch IS NULL AND base_sha IS NULL AND head_sha IS NULL AND worktree_clean IS NULL AND result IS NULL AND error IS NOT NULL)
    OR (status IN ('blocked','queued','provisioning','running','review') AND finished_at IS NULL AND result IS NULL AND error IS NULL)
    """)

    replace(:job_attempts, :job_attempts_lease_shape, """
    (status IN ('provisioning','running') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND capacity_reserved IS TRUE)
    OR (status = 'review' AND lease_token IS NOT NULL AND lease_expires_at IS NULL AND capacity_reserved IS FALSE)
    OR (status NOT IN ('provisioning','running','review') AND lease_token IS NULL AND lease_expires_at IS NULL AND capacity_reserved IS FALSE)
    """)

    replace(:job_events, :job_events_status_check, """
    status IN ('blocked','queued','provisioning','running','review','succeeded','failed','cancelled')
    """)

    replace(:api_tokens, :api_tokens_scopes_check, """
    cardinality(scopes) > 0 AND scopes <@ ARRAY['read','submit','cancel','review']::text[]
    """)

    replace(:token_audit_events, :token_audit_events_action_check, """
    action IN ('submit','cancel','retry','approve','reject','issue','rotate','revoke','redeliver')
    """)
  end

  def down do
    raise "no down - use mix ecto.reset"
  end

  defp replace(table, name, check) do
    drop constraint(table, name)
    create constraint(table, name, check: check)
  end
end
