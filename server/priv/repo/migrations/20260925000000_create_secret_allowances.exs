defmodule Omashiki.Repo.Migrations.CreateSecretAllowances do
  use Ecto.Migration

  # A finding an operator allowed: the secret scan drops it for later jobs of
  # the same environment, and of the same repository for a git sink.
  def up do
    create table(:secret_allowances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :fingerprint, :text, null: false
      add :environment, :text, null: false
      add :repository, :text
      add :file, :text, null: false
      add :rule_id, :text, null: false
      add :note, :text
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(
             :secret_allowances,
             [:fingerprint, :environment, "COALESCE(repository, '')"],
             name: :secret_allowances_scope_index
           )

    create index(:secret_allowances, [:environment, :repository])

    create constraint(:secret_allowances, :secret_allowances_fingerprint_hmac,
             check: "fingerprint ~ '^[0-9a-f]{64}$'"
           )
  end

  def down do
    raise "no down - use mix ecto.reset"
  end
end
