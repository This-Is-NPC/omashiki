defmodule Omashiki.Credentials.Credential do
  @moduledoc """
  A named LLM credential: `(provider, model, api_key)` bundle.

  Declared in `omashiki.toml` — `api_key` is plaintext TOML (not Cloak-encrypted).
  Never logged: the schema derives a redacting `Inspect`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @derive {Inspect, except: [:api_key]}

  embedded_schema do
    field :name, :string
    field :provider, :string
    field :model, :string
    field :base_url, :string
    field :api_key, :string, redact: true
    # TOML credential names (formerly binary_ids when DB-backed).
    field :fallback_chain, {:array, :string}, default: []
    field :model_aliases, :map, default: %{}
  end

  @doc """
  Full changeset — requires every field. Use for `create`.
  """
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :name,
      :provider,
      :model,
      :base_url,
      :api_key,
      :fallback_chain,
      :model_aliases
    ])
    |> validate_required([:name, :provider, :model, :api_key])
    |> normalize_base_url()
  end

  @doc """
  Update changeset — an empty `api_key` leaves the existing one intact.
  The form never echoes the stored key, so blank means "keep".
  """
  def update_changeset(credential, attrs) do
    attrs = maybe_drop_blank_api_key(attrs)

    credential
    |> cast(attrs, [
      :name,
      :provider,
      :model,
      :base_url,
      :api_key,
      :fallback_chain,
      :model_aliases
    ])
    |> validate_required([:name, :provider, :model])
    |> normalize_base_url()
  end

  # Empty-string `base_url` collapses to nil so `ContainerManager`'s clause
  # dispatch (`%Credential{base_url: nil}` ⇒ built-in provider config) keeps
  # working. Without this, `""` falls into the custom-OAI-compat branch and
  # opencode builds a broken `baseURL: ""` provider block.
  defp normalize_base_url(changeset) do
    case get_change(changeset, :base_url) do
      nil -> changeset
      "" -> put_change(changeset, :base_url, nil)
      url when is_binary(url) -> put_change(changeset, :base_url, String.trim(url))
      _ -> changeset
    end
  end

  defp maybe_drop_blank_api_key(attrs) do
    case Map.get(attrs, "api_key") || Map.get(attrs, :api_key) do
      nil -> attrs
      "" -> attrs |> Map.delete("api_key") |> Map.delete(:api_key)
      _ -> attrs
    end
  end
end
