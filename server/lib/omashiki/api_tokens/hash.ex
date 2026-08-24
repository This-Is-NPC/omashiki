defmodule Omashiki.ApiTokens.Hash do
  @moduledoc """
  HMAC-SHA256 over the secret key base. The plaintext bearer token is
  hashed before being persisted in `api_tokens.token_hash`. The pepper
  (secret key base) means a leaked DB on its own cannot be used to
  brute-force tokens — the attacker needs the runtime secret too.
  """

  @doc """
  Returns the hex-encoded HMAC-SHA256 digest of `plaintext`.
  """
  @spec hmac(binary()) :: String.t()
  def hmac(plaintext) when is_binary(plaintext) do
    :crypto.mac(:hmac, :sha256, secret(), plaintext)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Generates a fresh random plaintext token (256 bits, URL-safe Base64).
  """
  @spec generate_plaintext() :: String.t()
  def generate_plaintext do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp secret do
    Application.fetch_env!(:omashiki, OmashikiWeb.Endpoint)[:secret_key_base] ||
      raise "OmashikiWeb.Endpoint :secret_key_base is not configured"
  end
end
