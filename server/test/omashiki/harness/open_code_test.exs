defmodule Omashiki.Harness.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Omashiki.Plugin.Preset
  alias Omashiki.Isolation

  alias Omashiki.Harness.{Context, OpenCode}

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-harness-#{System.unique_integer([:positive])}")
    config = Path.join(root, "opencode.json")
    auth = Path.join(root, "auth.json")
    File.mkdir_p!(root)
    File.write!(config, ~s({"model":"openai/test-model"}))
    File.write!(auth, ~s({"openai":{"type":"api","key":"secret"}}))
    on_exit(fn -> File.rm_rf!(root) end)

    mounts = %{config => OpenCode.config_path(), auth => OpenCode.auth_path()}

    profile = %Preset{
      name: "opencode",
      adapter: OpenCode,
      adapter_key: "opencode",
      options: %{},
      runtime: %Isolation{
        key: "opencode",
        kind: "docker",
        config: %{"image" => "agent:latest"},
        status: "active"
      },
      launch_plan: nil
    }

    %{mounts: mounts, profile: profile}
  end

  test "host preparation references mounted snapshots without synthesizing a provider", %{
    mounts: mounts,
    profile: profile
  } do
    assert {:ok, delivery} =
             OpenCode.prepare(profile, %Context{profile: profile, runtime_mounts: mounts})

    assert delivery.llm_egress == :engine
    assert is_nil(delivery.secret)
    assert "OPENCODE_CONFIG_PATH=#{OpenCode.config_path()}" in delivery.environment
    assert "OPENCODE_AUTH_PATH=#{OpenCode.auth_path()}" in delivery.environment

    config =
      delivery.environment
      |> Enum.find(&String.starts_with?(&1, "OPENCODE_CONFIG_CONTENT="))
      |> String.replace_prefix("OPENCODE_CONFIG_CONTENT=", "")
      |> Jason.decode!()

    refute Map.has_key?(config, "model")
    refute Map.has_key?(config, "provider")
  end

  test "host preparation fails closed when a required snapshot is absent", %{
    mounts: mounts,
    profile: profile
  } do
    [{auth_source, _} | _] =
      Enum.filter(mounts, fn {_source, target} -> target == OpenCode.auth_path() end)

    File.rm!(auth_source)

    assert {:error, {:harness_auth_unavailable, ^auth_source}} =
             OpenCode.prepare(profile, %Context{profile: profile, runtime_mounts: mounts})
  end

  test "host-auth turns accept the neutral invocation" do
    assert %Omashiki.Harness.Invocation{instruction: "hello", context: nil} =
             Omashiki.Harness.Invocation.new(%{"instruction" => "hello"})
  end
end
