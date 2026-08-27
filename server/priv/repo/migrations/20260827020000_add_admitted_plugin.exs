defmodule Omashiki.Repo.Migrations.AddAdmittedPlugin do
  use Ecto.Migration

  def up do
    execute "DROP TRIGGER IF EXISTS jobs_identity_immutable ON jobs"
    execute "DROP FUNCTION IF EXISTS prevent_job_identity_update()"

    alter table(:jobs) do
      add :admitted_plugin, :map
      add :admitted_plugin_digest, :string
    end

    create constraint(:jobs, :jobs_admitted_plugin_digest_sha256,
             check: "admitted_plugin_digest IS NULL OR admitted_plugin_digest ~ '^[0-9a-f]{64}$'"
           )

    execute """
    CREATE FUNCTION prevent_job_identity_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.user_id, OLD.api_token_id, OLD.parent_job_id, OLD.schema_version, OLD.idempotency_key,
             OLD.correlation_id, OLD.repository, OLD.environment, OLD.payload, OLD.payload_hash,
             OLD.admitted_repository, OLD.admitted_repository_digest, OLD.admitted_environment,
             OLD.admitted_environment_digest, OLD.admitted_plugin, OLD.admitted_plugin_digest,
             OLD.registry_digest, OLD.queue, OLD.priority)
         IS DISTINCT FROM
         ROW(NEW.user_id, NEW.api_token_id, NEW.parent_job_id, NEW.schema_version, NEW.idempotency_key,
             NEW.correlation_id, NEW.repository, NEW.environment, NEW.payload, NEW.payload_hash,
             NEW.admitted_repository, NEW.admitted_repository_digest, NEW.admitted_environment,
             NEW.admitted_environment_digest, NEW.admitted_plugin, NEW.admitted_plugin_digest,
             NEW.registry_digest, NEW.queue, NEW.priority) THEN
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

    drop constraint(:jobs, :jobs_admitted_plugin_digest_sha256)

    alter table(:jobs) do
      remove :admitted_plugin_digest
      remove :admitted_plugin
    end

    execute """
    CREATE FUNCTION prevent_job_identity_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.user_id, OLD.api_token_id, OLD.parent_job_id, OLD.schema_version, OLD.idempotency_key,
             OLD.correlation_id, OLD.repository, OLD.environment, OLD.payload, OLD.payload_hash,
             OLD.admitted_repository, OLD.admitted_repository_digest, OLD.admitted_environment,
             OLD.admitted_environment_digest, OLD.registry_digest, OLD.queue, OLD.priority)
         IS DISTINCT FROM
         ROW(NEW.user_id, NEW.api_token_id, NEW.parent_job_id, NEW.schema_version, NEW.idempotency_key,
             NEW.correlation_id, NEW.repository, NEW.environment, NEW.payload, NEW.payload_hash,
             NEW.admitted_repository, NEW.admitted_repository_digest, NEW.admitted_environment,
             NEW.admitted_environment_digest, NEW.registry_digest, NEW.queue, NEW.priority) THEN
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
