defmodule Omashiki.Jobs.SecretAllowance do
  @moduledoc "A secret-scan finding an operator allowed in one environment."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "secret_allowances" do
    field :fingerprint, :string
    field :environment, :string
    field :repository, :string
    field :file, :string
    field :rule_id, :string
    field :note, :string

    belongs_to :created_by, Omashiki.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(allowance, attrs) do
    allowance
    |> cast(attrs, [
      :fingerprint,
      :environment,
      :repository,
      :file,
      :rule_id,
      :note,
      :created_by_id
    ])
    |> validate_required([:fingerprint, :environment, :file, :rule_id])
    |> validate_format(:fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:note, max: 500)
    |> unique_constraint([:fingerprint, :environment], name: :secret_allowances_scope_index)
    |> check_constraint(:fingerprint, name: :secret_allowances_fingerprint_hmac)
    |> foreign_key_constraint(:created_by_id)
  end
end
