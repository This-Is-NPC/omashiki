defmodule Omashiki.PresetsTest do
  use ExUnit.Case, async: true

  alias Omashiki.Presets
  alias Omashiki.Plugin.Preset
  alias Omashiki.Runtime.Spec

  test "reconstructs a preset from plugin and resolved runtime snapshot keys" do
    environment = %{
      "preset" => %{
        "name" => "opencode",
        "plugin" => "opencode",
        "options" => %{},
        "runtime" => %{
          "name" => "docker.runc.debian",
          "backend" => "docker",
          "handler" => "runc",
          "distribution" => "debian",
          "plugin" => "opencode",
          "image" => "agent"
        },
        "launch_plan" => %{
          "runtime" => %{
            "name" => "docker.runc.debian",
            "backend" => "docker",
            "handler" => "runc",
            "distribution" => "debian",
            "plugin" => "opencode",
            "image" => "agent"
          },
          "transport" => %{"kind" => "cli"}
        },
        "manifest" => nil
      },
      "runtime" => %{
        "name" => "docker.runc.debian",
        "backend" => "docker",
        "handler" => "runc",
        "distribution" => "debian",
        "plugin" => "opencode",
        "image" => "agent"
      }
    }

    profile = Presets.profile(environment)

    assert %Preset{name: "opencode", plugin: "opencode"} = profile

    assert %Spec{backend: "docker", handler: "runc", distribution: "debian", image: "agent"} =
             profile.runtime

    assert Presets.plugin(profile) == "opencode"
    assert Presets.adapter(profile) == Omashiki.Plugin.Interpreter
  end

  test "does not read legacy runtime keys from the preset snapshot" do
    environment = %{
      "preset" => %{
        "name" => "opencode",
        "plugin" => "opencode",
        "options" => %{},
        "runtime" => %{"kind" => "docker", "config" => %{"image" => "agent"}}
      },
      "runtime" => %{
        "name" => "docker.debian",
        "backend" => "docker",
        "distribution" => "debian",
        "plugin" => "opencode",
        "image" => "agent"
      }
    }

    assert_raise ArgumentError, ~r/invalid resolved runtime/, fn ->
      Presets.profile(environment)
    end
  end

  test "resolved runtime has an immutable typed shape" do
    runtime = %Spec{
      name: "docker.runc.debian",
      backend: "docker",
      handler: "runc",
      distribution: "debian",
      plugin: "opencode",
      image: "agent"
    }

    assert runtime.name == "docker.runc.debian"
  end
end
