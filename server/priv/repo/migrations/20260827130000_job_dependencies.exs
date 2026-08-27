defmodule Omashiki.Repo.Migrations.JobDependencies do
  use Ecto.Migration

  def up do
    execute "DROP TRIGGER IF EXISTS jobs_identity_immutable ON jobs"
    execute "DROP FUNCTION IF EXISTS prevent_job_identity_update()"

    create table(:job_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :depends_on_job_id, references(:jobs, type: :binary_id, on_delete: :restrict),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :on_failure, :text, null: false, default: "cancel"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:job_dependencies, [:job_id, :depends_on_job_id])
    create index(:job_dependencies, [:depends_on_job_id])
    create index(:job_dependencies, [:user_id])

    create constraint(:job_dependencies, :job_dependencies_not_self,
             check: "job_id <> depends_on_job_id"
           )

    create constraint(:job_dependencies, :job_dependencies_on_failure_check,
             check: "on_failure IN ('cancel', 'block', 'proceed')"
           )

    execute """
    ALTER TABLE job_dependencies
    ADD CONSTRAINT job_dependencies_job_owner_fkey
    FOREIGN KEY (job_id, user_id) REFERENCES jobs(id, user_id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE job_dependencies
    ADD CONSTRAINT job_dependencies_dep_owner_fkey
    FOREIGN KEY (depends_on_job_id, user_id) REFERENCES jobs(id, user_id) ON DELETE RESTRICT
    """

    alter table(:jobs) do
      add :dependency_artifacts, :map
    end

    drop constraint(:jobs, :jobs_blocked_requires_parent)
    drop constraint(:jobs, :jobs_parent_not_self)
    drop index(:jobs, [:parent_job_id])

    execute "ALTER TABLE jobs DROP CONSTRAINT IF EXISTS jobs_parent_owner_fkey"

    alter table(:jobs) do
      remove :parent_job_id
    end

    execute """
    CREATE FUNCTION prevent_job_identity_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.user_id, OLD.api_token_id, OLD.schema_version, OLD.idempotency_key,
             OLD.correlation_id, OLD.repository, OLD.environment, OLD.payload, OLD.payload_hash,
             OLD.admitted_repository, OLD.admitted_repository_digest, OLD.admitted_environment,
             OLD.admitted_environment_digest, OLD.admitted_plugin, OLD.admitted_plugin_digest,
             OLD.registry_digest, OLD.queue, OLD.priority)
         IS DISTINCT FROM
         ROW(NEW.user_id, NEW.api_token_id, NEW.schema_version, NEW.idempotency_key,
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

    alter table(:jobs) do
      add :parent_job_id, references(:jobs, type: :binary_id, on_delete: :restrict)
    end

    create index(:jobs, [:parent_job_id])

    create constraint(:jobs, :jobs_parent_not_self,
             check: "parent_job_id IS NULL OR parent_job_id <> id"
           )

    create constraint(:jobs, :jobs_blocked_requires_parent,
             check: "status <> 'blocked' OR parent_job_id IS NOT NULL"
           )

    execute """
    ALTER TABLE jobs
    ADD CONSTRAINT jobs_parent_owner_fkey
    FOREIGN KEY (parent_job_id, user_id) REFERENCES jobs(id, user_id) ON DELETE RESTRICT
    """

    alter table(:jobs) do
      remove :dependency_artifacts
    end

    drop table(:job_dependencies)

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
end
