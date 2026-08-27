defmodule Omashiki.Repo.Migrations.OptionalRepositoryAndSinkTerminalShapes do
  use Ecto.Migration

  def up do
    drop constraint(:jobs, :jobs_admitted_repository_digest_sha256)
    drop constraint(:job_attempts, :job_attempts_terminal_shape)

    alter table(:jobs) do
      modify :repository, :text, null: true
      modify :admitted_repository, :map, null: true
      modify :admitted_repository_digest, :text, null: true
    end

    create constraint(:jobs, :jobs_admitted_repository_digest_sha256,
             check: """
             (admitted_repository IS NULL AND admitted_repository_digest IS NULL)
             OR (admitted_repository IS NOT NULL AND admitted_repository_digest ~ '^[0-9a-f]{64}$')
             """
           )

    create constraint(:job_attempts, :job_attempts_terminal_shape,
             check: """
             (status = 'succeeded' AND finished_at IS NOT NULL AND result IS NOT NULL AND error IS NULL AND (
               (branch IS NOT NULL AND base_sha IS NOT NULL AND head_sha IS NOT NULL AND worktree_clean IS TRUE)
               OR
               (branch IS NULL AND base_sha IS NULL AND head_sha IS NULL AND worktree_clean IS NULL)
             ))
             OR (status IN ('failed','cancelled') AND finished_at IS NOT NULL AND branch IS NULL AND base_sha IS NULL AND head_sha IS NULL AND worktree_clean IS NULL AND result IS NULL AND error IS NOT NULL)
              OR (status IN ('blocked','queued','provisioning','running') AND finished_at IS NULL AND result IS NULL AND error IS NULL)
             """
           )
  end

  def down do
    drop constraint(:jobs, :jobs_admitted_repository_digest_sha256)
    drop constraint(:job_attempts, :job_attempts_terminal_shape)

    alter table(:jobs) do
      modify :repository, :text, null: false
      modify :admitted_repository, :map, null: false
      modify :admitted_repository_digest, :text, null: false
    end

    create constraint(:jobs, :jobs_admitted_repository_digest_sha256,
             check: "admitted_repository_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:job_attempts, :job_attempts_terminal_shape,
             check: """
             (status = 'succeeded' AND finished_at IS NOT NULL AND branch IS NOT NULL AND base_sha IS NOT NULL AND head_sha IS NOT NULL AND worktree_clean IS TRUE AND result IS NOT NULL AND error IS NULL)
             OR (status IN ('failed','cancelled') AND finished_at IS NOT NULL AND branch IS NULL AND base_sha IS NULL AND head_sha IS NULL AND worktree_clean IS NULL AND result IS NULL AND error IS NOT NULL)
              OR (status IN ('blocked','queued','provisioning','running') AND finished_at IS NULL AND result IS NULL AND error IS NULL)
             """
           )
  end
end
