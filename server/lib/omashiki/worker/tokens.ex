defmodule Omashiki.Worker.Tokens do
  @moduledoc false

  @doc "True when a non-empty worker token is configured."
  def configured? do
    case Application.get_env(:omashiki, :worker_token) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @doc "Validate a presented worker token against the configured secret."
  def valid?(plaintext) when is_binary(plaintext) do
    case Application.get_env(:omashiki, :worker_token) do
      token when is_binary(token) and token != "" ->
        byte_size(token) == byte_size(plaintext) and
          Plug.Crypto.secure_compare(token, plaintext)

      _ ->
        false
    end
  end

  def valid?(_), do: false
end
