defmodule Omashiki.Gateway.Providers.AnthropicNative do
  @moduledoc """
  Placeholder for the Anthropic **Messages** outbound adapter.

  Not implemented in Phase 4. When shipped it will:

  * Accept the inbound OpenAI-compat body from the engine
  * Translate to Anthropic Messages (`/v1/messages`)
  * Return an OpenAI-shaped `response` for the engine **and** ledger
    `usage` with real `cache_read_input_tokens` /
    `cache_creation_input_tokens` (mapped to `cached_input_tokens` /
    `cache_write_tokens`)

  Wire it without gateway rework:

      config :omashiki, :gateway_provider_adapters,
        %{"anthropic" => Omashiki.Gateway.Providers.AnthropicNative}

  Until then, `Provider.adapter/1` falls through to `OpenaiCompat`, which
  documents that Anthropic OAI-compat leaves cache/reasoning columns as `nil`.

  ## Not a URL swap

  Request body translation, response shaping back to OAI for the engine, and
   usage normalisation (especially `cache_creation_input_tokens` /
   `cache_read_input_tokens`) all live in the adapter.
  """

  @behaviour Omashiki.Gateway.Provider

  alias Omashiki.Credentials.Credential

  @impl true
  def chat_completions(%Credential{}, _body, _model) do
    {:error,
     %{
       status: 501,
       error: %{
         message:
           "AnthropicNative adapter not implemented; use OpenaiCompat or wait for Messages translate",
         type: "not_implemented"
       }
     }}
  end
end
