defmodule Omashiki.Credentials do
  @moduledoc """
  LLM credentials from `omashiki.toml` via `Omashiki.Config`.

  Identity is the credential **name**. Gateway tokens carry that name.
  """

  alias Omashiki.Config
  alias Omashiki.Credentials.Credential

  def list_credentials, do: Config.credentials()

  def get_credential!(name) when is_binary(name) do
    case get_credential(name) do
      nil -> raise Ecto.NoResultsError, queryable: "credentials"
      cred -> cred
    end
  end

  def get_credential(nil), do: nil
  def get_credential(name) when is_binary(name), do: Config.get_credential(name)

  def get_by_name(name) when is_binary(name), do: get_credential(name)

  @doc """
  Masked representation of the key for list views.
  """
  def masked_key(%Credential{api_key: nil}), do: "****"
  def masked_key(%Credential{api_key: key}) when is_binary(key) and byte_size(key) < 8, do: "****"

  def masked_key(%Credential{api_key: key}) when is_binary(key),
    do: "****" <> binary_part(key, byte_size(key) - 4, 4)

  def masked_key(%Credential{}), do: "****"
end
