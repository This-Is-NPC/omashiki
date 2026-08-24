defmodule Omashiki.Gateway.Provider do
  @moduledoc """
  Outbound provider seam for the LLM gateway.

  **Inbound** (engine → Omashiki) stays OpenAI-compatible forever.
  **Outbound** (Omashiki → provider) is adapter-selected per credential so
  Anthropic-native (Messages API + real cache token fields) can land without
  rewriting the gateway core.

  Today the only shipped adapter is `OpenaiCompat`. Selection:

      Provider.adapter(credential) → module

  Override via Application env:

      config :omashiki, :gateway_provider_adapters, %{"anthropic" => MyNative}
  """

  alias Omashiki.Credentials.Credential

  @type usage :: %{
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:cached_input_tokens) => non_neg_integer() | nil,
          required(:cache_write_tokens) => non_neg_integer() | nil,
          required(:reasoning_tokens) => non_neg_integer() | nil,
          required(:provider_request_id) => String.t() | nil
        }

  @type result :: %{
          required(:response) => map(),
          required(:usage) => usage()
        }

  @callback chat_completions(Credential.t(), body :: map(), model :: String.t()) ::
              {:ok, result()} | {:error, term()}

  @doc "Resolve outbound adapter module for a credential."
  def adapter(%Credential{provider: provider} = cred) do
    overrides = Application.get_env(:omashiki, :gateway_provider_adapters, %{}) || %{}

    # Note: `nil` is an atom in Elixir — never treat a missing map entry as an override.
    case Map.get(overrides, provider) || Map.get(overrides, to_string(provider)) do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> default_adapter(cred)
    end
  end

  defp default_adapter(%Credential{}) do
    # Full module atom at runtime — do NOT `alias` OpenaiCompat here or you
    # get a compile cycle with `@behaviour Omashiki.Gateway.Provider` and
    # the alias collapses to `nil`.
    Omashiki.Gateway.Providers.OpenaiCompat
  end

  @doc "Forward one completion through the credential's outbound adapter."
  def chat_completions(%Credential{} = cred, body, model) when is_map(body) do
    adapter(cred).chat_completions(cred, body, model)
  end
end
