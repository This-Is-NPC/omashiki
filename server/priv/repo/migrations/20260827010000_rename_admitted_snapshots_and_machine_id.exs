defmodule Omashiki.Repo.Migrations.RenameAdmittedSnapshotsAndMachineId do
  use Ecto.Migration

  def up do
    execute "DROP TRIGGER IF EXISTS jobs_identity_immutable ON jobs"
    execute "DROP FUNCTION IF EXISTS prevent_job_identity_update()"

    drop constraint(:jobs, :jobs_repository_digest_sha256)
    drop constraint(:jobs, :jobs_environment_digest_sha256)

    rename table(:jobs), :repository_snapshot, to: :admitted_repository
    rename table(:jobs), :repository_digest, to: :admitted_repository_digest
    rename table(:jobs), :environment_snapshot, to: :admitted_environment
    rename table(:jobs), :environment_digest, to: :admitted_environment_digest

    rename table(:job_attempts), :node_id, to: :machine_id

    create constraint(:jobs, :jobs_admitted_repository_digest_sha256,
             check: "admitted_repository_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:jobs, :jobs_admitted_environment_digest_sha256,
             check: "admitted_environment_digest ~ '^[0-9a-f]{64}$'"
           )

    execute """
    CREATE FUNCTION prevent_job_identity_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.user_id, OLD.api_token_id, OLD.parent_job_id, OLD.schema_version,
             OLD.idempotency_key, OLD.correlation_id, OLD.repository, OLD.environment,
             OLD.payload, OLD.payload_hash, OLD.admitted_repository, OLD.admitted_repository_digest,
             OLD.admitted_environment, OLD.admitted_environment_digest, OLD.registry_digest,
             OLD.queue, OLD.priority)
         IS DISTINCT FROM
         ROW(NEW.user_id, NEW.api_token_id, NEW.parent_job_id, NEW.schema_version,
             NEW.idempotency_key, NEW.correlation_id, NEW.repository, NEW.environment,
             NEW.payload, NEW.payload_hash, NEW.admitted_repository, NEW.admitted_repository_digest,
             NEW.admitted_environment, NEW.admitted_environment_digest, NEW.registry_digest,
             NEW.queue, NEW.priority) THEN
        RAISE EXCEPTION 'admitted job identity is immutable' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER jobs_identity_immutable
    BEFORE UPDATE ON jobs
    FOR EACH ROW EXECUTE FUNCTION prevent_job_identity_update()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS jobs_identity_immutable ON jobs"
    execute "DROP FUNCTION IF EXISTS prevent_job_identity_update()"

    drop constraint(:jobs, :jobs_admitted_repository_digest_sha256)
    drop constraint(:jobs, :jobs_admitted_environment_digest_sha256)

    rename table(:job_attempts), :machine_id, to: :node_id

    rename table(:jobs), :admitted_environment_digest, to: :environment_digest
    rename table(:jobs), :admitted_environment, to: :environment_snapshot
    rename table(:jobs), :admitted_repository_digest, to: :repository_digest
    rename table(:jobs), :admitted_repository, to: :repository_snapshot

    create constraint(:jobs, :jobs_repository_digest_sha256,
             check: "repository_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:jobs, :jobs_environment_digest_sha256,
             check: "environment_digest ~ '^[0-9a-f]{64}$'"
           )

    execute """
    CREATE FUNCTION prevent_job_identity_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.user_id, OLD.api_token_id, OLD.parent_job_id, OLD.schema_version,
             OLD.idempotency_key, OLD.correlation_id, OLD.repository, OLD.environment,
             OLD.payload, OLD.payload_hash, OLD.repository_snapshot, OLD.repository_digest,
             OLD.environment_snapshot, OLD.environment_digest, OLD.registry_digest,
             OLD.queue, OLD.priority)
         IS DISTINCT FROM
         ROW(NEW.user_id, NEW.api_token_id, NEW.parent_job_id, NEW.schema_version,
             NEW.idempotency_key, NEW.correlation_id, NEW.repository, NEW.environment,
             NEW.payload, NEW.payload_hash, NEW.repository_snapshot, NEW.repository_digest,
             NEW.environment_snapshot, NEW.environment_digest, NEW.registry_digest,
             NEW.queue, NEW.priority) THEN
        RAISE EXCEPTION 'admitted job identity is immutable' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER jobs_identity_immutable
    BEFORE UPDATE ON jobs
    FOR EACH ROW EXECUTE FUNCTION prevent_job_identity_update()
    """
  end
end
