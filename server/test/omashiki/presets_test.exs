defmodule Omashiki.PresetsTest do
  use ExUnit.Case, async: true

  alias Omashiki.Presets
  alias Omashiki.Plugin.Preset
  alias Omashiki.Isolation

  test "reconstructs a preset from plugin and isolation snapshot keys" do
    environment = %{
      "preset" => %{
        "name" => "opencode",
        "plugin" => "opencode",
        "options" => %{},
        "isolation" => %{"kind" => "docker", "config" => %{"image" => "agent"}},
        "launch_plan" => %{"transport" => %{"kind" => "cli"}},
        "manifest" => nil
      }
    }

    profile = Presets.profile(environment)

    assert %Preset{name: "opencode", plugin: "opencode"} = profile
    assert %Isolation{kind: "docker"} = profile.isolation
    assert Presets.plugin(profile) == "opencode"
    assert Presets.adapter(profile) == Omashiki.Plugin.Interpreter
  end

  test "does not read adapter_key or runtime snapshot keys" do
    environment = %{
      "preset" => %{
        "name" => "opencode",
        "adapter_key" => "opencode",
        "options" => %{},
        "runtime" => %{"kind" => "docker", "config" => %{"image" => "agent"}}
      }
    }

    assert_raise ArgumentError, ~r/invalid resolved preset/, fn ->
      Presets.profile(environment)
    end
  end
end
