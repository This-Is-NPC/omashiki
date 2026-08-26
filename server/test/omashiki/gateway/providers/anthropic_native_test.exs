defmodule Omashiki.Gateway.Providers.AnthropicNativeTest do
  @moduledoc """
  The Anthropic Messages adapter is a documented placeholder. What matters is
  that it fails **loudly**: wiring it by config must produce a 501, not a
  silently empty turn that the engine reads as "the model had nothing to say".
  """

  use ExUnit.Case, async: false

  alias Omashiki.Credentials.Credential
  alias Omashiki.Gateway.Provider
  alias Omashiki.Gateway.Providers.AnthropicNative

  setup do
    previous = Application.get_env(:omashiki, :gateway_provider_adapters)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:omashiki, :gateway_provider_adapters)
        value -> Application.put_env(:omashiki, :gateway_provider_adapters, value)
      end
    end)

    :ok
  end

  test "refuses with 501 rather than returning an empty completion" do
    assert {:error, %{status: 501, error: %{type: "not_implemented", message: message}}} =
             AnthropicNative.chat_completions(
               cred(),
               %{"messages" => [%{"role" => "user", "content" => "hi"}]},
               "claude-sonnet-4-5"
             )

    assert message =~ "not implemented"
  end

  test "never invents a response or usage map" do
    assert {:error, payload} = AnthropicNative.chat_completions(cred(), %{}, "any-model")
    refute Map.has_key?(payload, :response)
    refute Map.has_key?(payload, :usage)
  end

  test "refuses identically whatever the body and model" do
    for body <- [%{}, %{"messages" => []}, %{"stream" => true}] do
      assert {:error, %{status: 501}} = AnthropicNative.chat_completions(cred(), body, "m")
    end
  end

  test "is reachable through the documented config wiring" do
    Application.put_env(:omashiki, :gateway_provider_adapters, %{
      "anthropic" => AnthropicNative
    })

    assert Provider.adapter(cred()) == AnthropicNative
    assert {:error, %{status: 501}} = Provider.chat_completions(cred(), %{"messages" => []}, "m")
  end

  defp cred do
    %Credential{
      name: "anthropic-cred",
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      api_key: "sk-ant-test"
    }
  end
end
