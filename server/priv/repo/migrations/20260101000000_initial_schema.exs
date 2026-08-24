defmodule Omashiki.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  @moduledoc """
  Clean queue-only schema. Declarative repository/environment configuration
  lives in `omashiki.toml`; PostgreSQL stores admitted jobs and their effects.

  There is intentionally no legacy migration or `down`; use `mix ecto.reset`.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public"
    Oban.Migration.up(version: 14)

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :username, :citext, null: false
      add :password_hash, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:username])
    create constraint(:users, :users_email_not_blank, check: "btrim(email::text) <> ''")
    create constraint(:users, :users_username_not_blank, check: "btrim(username::text) <> ''")

    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :token_hash, :text, null: false
      add :last_used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :webhook_destination, :text
      add :webhook_secret_ciphertext, :text
      add :webhook_previous_secret_ciphertext, :text
      add :webhook_key_id, :text
      add :webhook_previous_key_id, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])
    create unique_index(:api_tokens, [:id, :user_id])
    create index(:api_tokens, [:user_id, :inserted_at])
    create constraint(:api_tokens, :api_tokens_name_not_blank, check: "btrim(name) <> ''")

    create table(:jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :api_token_id, references(:api_tokens, type: :binary_id, on_delete: :nilify_all)
      add :parent_job_id, references(:jobs, type: :binary_id, on_delete: :restrict)
      add :schema_version, :integer, null: false, default: 1
      add :idempotency_key, :text, null: false
      add :correlation_id, :text, null: false
      add :repository, :text, null: false
      add :environment, :text, null: false
      add :payload, :map, null: false
      add :payload_hash, :text, null: false
      add :repository_snapshot, :map, null: false
      add :repository_digest, :text, null: false
      add :environment_snapshot, :map, null: false
      add :environment_digest, :text, null: false
      add :registry_digest, :text, null: false
      add :queue, :text, null: false, default: "default"
      add :priority, :integer, null: false, default: 0
      add :status, :text, null: false
      add :current_attempt, :integer, null: false, default: 1
      add :queued_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :terminal_result, :map
      add :terminal_error, :map
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:jobs, [:user_id, :idempotency_key])
    create unique_index(:jobs, [:id, :user_id])
    create index(:jobs, [:parent_job_id])
    create index(:jobs, [:api_token_id])
    create index(:jobs, [:correlation_id])
    create index(:jobs, [:status])

    create index(:jobs, [:queue, desc: :priority, asc: :queued_at, asc: :id],
             name: :jobs_queue_order_index,
             where: "status = 'queued'"
           )

    create index(:jobs, [:finished_at], using: "BRIN")
    create constraint(:jobs, :jobs_schema_version_check, check: "schema_version = 1")
    create constraint(:jobs, :jobs_priority_check, check: "priority BETWEEN 0 AND 3")
    create constraint(:jobs, :jobs_current_attempt_positive, check: "current_attempt > 0")

    create constraint(:jobs, :jobs_parent_not_self,
             check: "parent_job_id IS NULL OR parent_job_id <> id"
           )

    create constraint(:jobs, :jobs_status_check,
             check:
               "status IN ('blocked','queued','provisioning','running','succeeded','failed','cancelled')"
           )

    create constraint(:jobs, :jobs_blocked_requires_parent,
             check: "status <> 'blocked' OR parent_job_id IS NOT NULL"
           )

    create constraint(:jobs, :jobs_queue_timestamps,
             check:
               "(status = 'blocked' AND queued_at IS NULL) OR status = 'cancelled' OR (status IN ('queued','provisioning','running','succeeded','failed') AND queued_at IS NOT NULL)"
           )

    create constraint(:jobs, :jobs_start_timestamps,
             check:
               "(status IN ('blocked','queued') AND started_at IS NULL) OR status = 'cancelled' OR (status IN ('provisioning','running','succeeded','failed') AND started_at IS NOT NULL)"
           )

    create constraint(:jobs, :jobs_payload_size_check,
             check: "octet_length(payload::text) <= 1048576"
           )

    for field <- ~w(payload_hash repository_digest environment_digest registry_digest) do
      create constraint(:jobs, String.to_atom("jobs_#{field}_sha256"),
               check: "#{field} ~ '^[0-9a-f]{64}$'"
             )
    end

    create constraint(:jobs, :jobs_terminal_shape,
             check: """
             (status = 'succeeded' AND finished_at IS NOT NULL AND terminal_result IS NOT NULL AND terminal_error IS NULL)
             OR (status IN ('failed','cancelled') AND finished_at IS NOT NULL AND terminal_result IS NULL AND terminal_error IS NOT NULL)
              OR (status IN ('blocked','queued','provisioning','running') AND finished_at IS NULL AND terminal_result IS NULL AND terminal_error IS NULL)
             """
           )

    execute """
    ALTER TABLE jobs
    ADD CONSTRAINT jobs_api_token_owner_fkey
    FOREIGN KEY (api_token_id, user_id) REFERENCES api_tokens(id, user_id) ON DELETE RESTRICT
    """

    execute """
    ALTER TABLE jobs
    ADD CONSTRAINT jobs_parent_owner_fkey
    FOREIGN KEY (parent_job_id, user_id) REFERENCES jobs(id, user_id) ON DELETE RESTRICT
    """

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

    create table(:execution_capacity, primary_key: false) do
      add :id, :integer, primary_key: true
      add :capacity, :integer, null: false, default: 8
      add :active, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    execute "INSERT INTO execution_capacity (id, capacity, active, inserted_at, updated_at) VALUES (1, 8, 0, NOW(), NOW())"
    create constraint(:execution_capacity, :execution_capacity_id_check, check: "id = 1")

    create constraint(:execution_capacity, :execution_capacity_values_check,
             check: "capacity = 8 AND active >= 0 AND active <= capacity"
           )

    create table(:job_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :status, :text, null: false
      add :oban_job_id, references(:oban_jobs, type: :bigint, on_delete: :nilify_all)
      add :runner_id, :text
      add :lease_token, :text
      add :lease_expires_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec
      add :claimed_at, :utc_datetime_usec
      add :capacity_reserved, :boolean, null: false, default: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :branch, :text
      add :base_sha, :text
      add :head_sha, :text
      add :worktree_clean, :boolean
      add :result, :map
      add :error, :map
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:job_attempts, [:job_id, :number])
    create unique_index(:job_attempts, [:id, :job_id])
    create unique_index(:job_attempts, [:oban_job_id], where: "oban_job_id IS NOT NULL")

    create unique_index(:job_attempts, [:job_id],
             name: :job_attempts_one_active_per_job,
             where: "status IN ('provisioning','running')"
           )

    create index(:job_attempts, [:status])

    create index(:job_attempts, [:lease_expires_at],
             name: :job_attempts_expired_leases_index,
             where: "status IN ('provisioning','running')"
           )

    create index(:job_attempts, [:finished_at], using: "BRIN")
    create constraint(:job_attempts, :job_attempts_number_positive, check: "number > 0")

    create constraint(:job_attempts, :job_attempts_status_check,
             check:
               "status IN ('blocked','queued','provisioning','running','succeeded','failed','cancelled')"
           )

    create constraint(:job_attempts, :job_attempts_start_timestamps,
             check:
               "(status IN ('blocked','queued') AND started_at IS NULL) OR status = 'cancelled' OR (status IN ('provisioning','running','succeeded','failed') AND started_at IS NOT NULL)"
           )

    create constraint(:job_attempts, :job_attempts_terminal_shape,
             check: """
             (status = 'succeeded' AND finished_at IS NOT NULL AND branch IS NOT NULL AND base_sha IS NOT NULL AND head_sha IS NOT NULL AND worktree_clean IS TRUE AND result IS NOT NULL AND error IS NULL)
             OR (status IN ('failed','cancelled') AND finished_at IS NOT NULL AND branch IS NULL AND base_sha IS NULL AND head_sha IS NULL AND worktree_clean IS NULL AND result IS NULL AND error IS NOT NULL)
              OR (status IN ('blocked','queued','provisioning','running') AND finished_at IS NULL AND result IS NULL AND error IS NULL)
             """
           )

    create constraint(:job_attempts, :job_attempts_lease_shape,
             check:
               "(status IN ('provisioning','running') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND capacity_reserved IS TRUE) OR (status NOT IN ('provisioning','running') AND lease_token IS NULL AND lease_expires_at IS NULL AND capacity_reserved IS FALSE)"
           )

    create constraint(:job_attempts, :job_attempts_base_sha_check,
             check: "base_sha IS NULL OR base_sha ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'"
           )

    create constraint(:job_attempts, :job_attempts_head_sha_check,
             check: "head_sha IS NULL OR head_sha ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'"
           )

    create table(:job_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :attempt_id, references(:job_attempts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :key, :text, null: false
      add :kind, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :input, :map
      add :output, :map
      add :error, :map
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:job_steps, [:attempt_id, :sequence])
    create unique_index(:job_steps, [:attempt_id, :key])
    create index(:job_steps, [:status])
    create constraint(:job_steps, :job_steps_sequence_positive, check: "sequence > 0")
    create constraint(:job_steps, :job_steps_key_not_blank, check: "btrim(key) <> ''")

    create constraint(:job_steps, :job_steps_status_check,
             check: "status IN ('pending','running','succeeded','failed','cancelled','skipped')"
           )

    create constraint(:job_steps, :job_steps_terminal_timestamps,
             check:
               "(status IN ('succeeded','failed','cancelled','skipped') AND finished_at IS NOT NULL) OR (status IN ('pending','running') AND finished_at IS NULL)"
           )

    create table(:job_events, primary_key: false) do
      add :event_id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :attempt, :integer, null: false
      add :sequence, :integer, null: false
      add :type, :text, null: false
      add :status, :text, null: false
      add :step, :text, null: false
      add :outcome, :text, null: false
      add :correlation_id, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      add :data, :map, null: false, default: %{}
      add :schema_version, :integer, null: false, default: 1
    end

    create unique_index(:job_events, [:job_id, :sequence])
    create index(:job_events, [:job_id, :attempt, :sequence])
    create index(:job_events, [:recorded_at])
    create index(:job_events, [:occurred_at], using: "BRIN")
    create constraint(:job_events, :job_events_attempt_positive, check: "attempt > 0")
    create constraint(:job_events, :job_events_sequence_positive, check: "sequence > 0")
    create constraint(:job_events, :job_events_schema_version_check, check: "schema_version = 1")

    create constraint(:job_events, :job_events_data_object_check,
             check: "jsonb_typeof(data) = 'object'"
           )

    create constraint(:job_events, :job_events_step_not_blank, check: "btrim(step) <> ''")

    create constraint(:job_events, :job_events_correlation_not_blank,
             check: "btrim(correlation_id) <> ''"
           )

    create constraint(:job_events, :job_events_status_check,
             check:
               "status IN ('blocked','queued','provisioning','running','succeeded','failed','cancelled')"
           )

    create constraint(:job_events, :job_events_type_status_check,
             check: "type = 'job.' || outcome AND status = outcome AND step = outcome"
           )

    execute """
    ALTER TABLE job_events
    ADD CONSTRAINT job_events_attempt_fkey
    FOREIGN KEY (job_id, attempt) REFERENCES job_attempts(job_id, number) ON DELETE CASCADE
    """

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_id,
          references(:job_events, column: :event_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :destination, :text, null: false
      add :idempotency_key, :binary_id, null: false
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: false
      add :delivered_at, :utc_datetime_usec
      add :last_response_status, :integer
      add :last_error, :map
      add :payload, :map, null: false
      add :payload_hash, :text, null: false
      add :signing_key_id, :text
      add :signing_secret_ciphertext, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_deliveries, [:event_id, :destination])
    create unique_index(:webhook_deliveries, [:destination, :idempotency_key])

    create index(:webhook_deliveries, [:status, :next_attempt_at, :id],
             name: :webhook_deliveries_outbox_index,
             where: "status IN ('pending','failed')"
           )

    create index(:webhook_deliveries, [:inserted_at], using: "BRIN")

    create constraint(:webhook_deliveries, :webhook_deliveries_attempts_nonnegative,
             check: "attempts >= 0"
           )

    create constraint(:webhook_deliveries, :webhook_deliveries_destination_not_blank,
             check: "btrim(destination) <> ''"
           )

    create constraint(:webhook_deliveries, :webhook_deliveries_payload_hash_sha256,
             check: "payload_hash ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:webhook_deliveries, :webhook_deliveries_event_idempotency,
             check: "idempotency_key = event_id"
           )

    create constraint(:webhook_deliveries, :webhook_deliveries_status_check,
             check: "status IN ('pending','delivering','delivered','failed','dead')"
           )

    create constraint(:webhook_deliveries, :webhook_deliveries_delivery_shape,
             check:
               "(status = 'delivered' AND delivered_at IS NOT NULL) OR (status <> 'delivered' AND delivered_at IS NULL)"
           )

    create table(:usage_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_id, :text, null: false
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :attempt_id, references(:job_attempts, type: :binary_id, on_delete: :nilify_all)
      add :turn, :integer
      add :source, :text
      add :provider, :text
      add :model, :text
      add :input_tokens, :integer, null: false, default: 0
      add :cached_input_tokens, :integer
      add :output_tokens, :integer, null: false, default: 0
      add :reasoning_tokens, :integer
      add :cache_write_tokens, :integer
      add :provider_request_id, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:usage_ledger, [:request_id])
    create index(:usage_ledger, [:job_id, :occurred_at])

    create unique_index(:usage_ledger, [:attempt_id, :turn],
             where: "attempt_id IS NOT NULL AND turn IS NOT NULL"
           )

    create index(:usage_ledger, [:occurred_at], using: "BRIN")

    create constraint(:usage_ledger, :usage_ledger_turn_positive,
             check: "turn IS NULL OR turn > 0"
           )

    create constraint(:usage_ledger, :usage_ledger_source_check,
             check: "source IS NULL OR source IN ('gateway','engine')"
           )

    create constraint(:usage_ledger, :usage_ledger_token_counts_nonnegative,
             check: """
             input_tokens >= 0 AND output_tokens >= 0
             AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0)
             AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0)
             AND (cache_write_tokens IS NULL OR cache_write_tokens >= 0)
             """
           )

    execute """
    ALTER TABLE usage_ledger
    ADD CONSTRAINT usage_ledger_attempt_job_fkey
    FOREIGN KEY (attempt_id, job_id) REFERENCES job_attempts(id, job_id) ON DELETE RESTRICT
    """
  end

  def down do
    raise "no down - use mix ecto.reset"
  end
end
