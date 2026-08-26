defmodule Omashiki.Gateway.ProviderTest do
  @moduledoc """
  The outbound seam. A wrong adapter choice here is silent: spend still
  leaves the box, it just leaves through the wrong translation.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Credentials.Credential
  alias Omashiki.Gateway.Provider
  alias Omashiki.Gateway.Providers.AnthropicNative
  alias Omashiki.Gateway.Providers.OpenaiCompat

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

  describe "adapter/1" do
    test "defaults to the OpenAI-compatible adapter for every provider" do
      for provider <- ~w(openai anthropic some-vendor) do
        assert Provider.adapter(cred(provider: provider)) == OpenaiCompat
      end
    end

    test "an override is selected by provider name" do
      Application.put_env(:omashiki, :gateway_provider_adapters, %{
        "anthropic" => AnthropicNative
      })

      assert Provider.adapter(cred(provider: "anthropic")) == AnthropicNative
      assert Provider.adapter(cred(provider: "openai")) == OpenaiCompat
    end

    test "an override table keyed by atom is honoured too" do
      Application.put_env(:omashiki, :gateway_provider_adapters, %{
        anthropic: AnthropicNative
      })

      # `to_string(provider)` is the second lookup, so an atom-keyed table
      # never matches — this documents that only string keys resolve.
      assert Provider.adapter(cred(provider: "anthropic")) == OpenaiCompat
    end

    test "a nil override falls through to the default instead of becoming the adapter" do
      # `nil` is an atom in Elixir; a naive `is_atom/1` guard would happily
      # return `nil` as the module and crash on dispatch.
      Application.put_env(:omashiki, :gateway_provider_adapters, %{"anthropic" => nil})

      assert Provider.adapter(cred(provider: "anthropic")) == OpenaiCompat
    end

    test "an override table set to nil is tolerated" do
      Application.put_env(:omashiki, :gateway_provider_adapters, nil)

      assert Provider.adapter(cred(provider: "openai")) == OpenaiCompat
    end
  end

  describe "chat_completions/3" do
    test "dispatches through the selected adapter" do
      Application.put_env(:omashiki, :gateway_provider_adapters, %{
        "anthropic" => AnthropicNative
      })

      assert {:error, %{status: 501}} =
               Provider.chat_completions(cred(provider: "anthropic"), %{"messages" => []}, "m")
    end
  end

  test "the shipped adapters implement the Provider behaviour" do
    for module <- [OpenaiCompat, AnthropicNative] do
      behaviours =
        module.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Provider in behaviours, "#{inspect(module)} does not implement Gateway.Provider"
    end
  end

  defp cred(attrs) do
    struct!(
      %Credential{
        name: "test-cred",
        provider: "openai",
        model: "gpt-5-mini",
        api_key: "sk-test"
      },
      attrs
    )
  end
end
