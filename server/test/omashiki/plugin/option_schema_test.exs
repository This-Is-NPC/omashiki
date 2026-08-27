defmodule Omashiki.Plugin.OptionSchemaTest do
  use ExUnit.Case, async: true

  alias Omashiki.Plugin.{Loader, OptionSchema}

  @plugins_dir Path.expand("../../../../plugins", __DIR__)

  setup do
    {:ok, plugins: Loader.load!(@plugins_dir)}
  end

  test "rejects unknown fields in manifest option specs", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "jcode")
    bad_options = Map.update!(manifest.options, "timeout_ms", &Map.put(&1, "bogus", true))

    assert_raise ArgumentError, ~r/unknown field/, fn ->
      OptionSchema.validate_schema!(%{manifest | options: bad_options}, "plugins/jcode.toml")
    end
  end

  test "validates jcode options", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "jcode")

    assert :ok = OptionSchema.validate(manifest, %{})
    assert {:error, {:unknown_options, ["web_search"]}} = OptionSchema.validate(manifest, %{"web_search" => true})
    assert {:error, :invalid_timeout} = OptionSchema.validate(manifest, %{"timeout_ms" => 0})
    assert {:error, :invalid_model} = OptionSchema.validate(manifest, %{"model" => "--oss"})
    assert {:error, :invalid_invocation_path} = OptionSchema.validate(manifest, %{"invocation_path" => "/etc/prompt.txt"})
  end

  test "validates claude-code options", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "claude-code")

    assert :ok = OptionSchema.validate(manifest, %{})
    assert {:error, {:unknown_options, ["extra"]}} = OptionSchema.validate(manifest, %{"extra" => true})
    assert {:error, :invalid_timeout} = OptionSchema.validate(manifest, %{"timeout_ms" => 0})
    assert {:error, :invalid_allowed_tools} = OptionSchema.validate(manifest, %{"allowed_tools" => ["Bash"]})
    assert {:error, :invalid_invocation_path} = OptionSchema.validate(manifest, %{"invocation_path" => "/etc/invocation.json"})
  end

  test "validates codex options", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "codex")

    assert :ok = OptionSchema.validate(manifest, %{})
    assert {:error, {:unknown_options, ["allowed_tools"]}} = OptionSchema.validate(manifest, %{"allowed_tools" => ["Read"]})
    assert {:error, :invalid_timeout} = OptionSchema.validate(manifest, %{"timeout_ms" => 0})
    assert {:error, :invalid_web_search} = OptionSchema.validate(manifest, %{"web_search" => "yes"})
    assert {:error, :invalid_model} = OptionSchema.validate(manifest, %{"model" => "--oss"})
    assert {:error, :invalid_reasoning_effort} = OptionSchema.validate(manifest, %{"reasoning_effort" => "lowest"})
    assert :ok = OptionSchema.validate(manifest, %{"reasoning_effort" => "low"})
    assert {:error, :invalid_invocation_path} = OptionSchema.validate(manifest, %{"invocation_path" => "/etc/invocation.json"})
    assert {:error, :invalid_credentials_path} = OptionSchema.validate(manifest, %{"credentials_path" => "/etc/codex-auth.json"})
  end

  test "validates pi options", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "pi")

    assert :ok = OptionSchema.validate(manifest, %{})
    assert {:error, {:unknown_options, ["thinking"]}} = OptionSchema.validate(manifest, %{"thinking" => "high"})
    assert {:error, :invalid_timeout} = OptionSchema.validate(manifest, %{"timeout_ms" => 0})
    assert {:error, :invalid_model} = OptionSchema.validate(manifest, %{"model" => "--offline"})
    assert {:error, :invalid_invocation_path} = OptionSchema.validate(manifest, %{"invocation_path" => "/etc/prompt.txt"})
  end

  test "validates opencode options", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "opencode")

    assert :ok = OptionSchema.validate(manifest, %{})
    assert {:error, {:unknown_options, ["extra"]}} = OptionSchema.validate(manifest, %{"extra" => true})
    assert {:error, :invalid_timeout} = OptionSchema.validate(manifest, %{"readiness_timeout_ms" => 0})
    assert {:error, :invalid_timeout} = OptionSchema.validate(manifest, %{"internal_port" => 0})
  end
end
