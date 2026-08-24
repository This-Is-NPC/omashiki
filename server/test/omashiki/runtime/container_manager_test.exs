defmodule Omashiki.Runtime.ContainerManagerTest do
  use ExUnit.Case, async: true

  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Harness.{LaunchPlan, Spec}
  alias Omashiki.Runtimes.Runtime

  test "CLI transport does not create an HTTP port binding" do
    config =
      ContainerManager.build_host_config(
        "/repo",
        "/repo/worktree",
        nil,
        1000,
        1000,
        network_mode: "none",
        internal_port: nil
      )

    refute Map.has_key?(config, "PortBindings")
  end

  test "HTTP transport still binds its internal port to localhost" do
    config =
      ContainerManager.build_host_config(
        "/repo",
        "/repo/worktree",
        14_096,
        1000,
        1000,
        network_mode: "none",
        internal_port: 4096
      )

    assert config["PortBindings"] == %{
             "4096/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "14096"}]
           }
  end

  test "container config recognizes a CLI plan with serializable string transport keys" do
    runtime = %Runtime{
      key: "claude-code",
      kind: "docker",
      config: %{"image" => "agent-claude"},
      status: "active"
    }

    plan = %LaunchPlan{
      runtime: runtime,
      transport: %{"kind" => "cli"},
      startup: nil,
      readiness: nil,
      secret: nil,
      environment: []
    }

    profile = %Spec{
      name: "claude-code",
      adapter: Omashiki.Harness.ClaudeCode,
      adapter_key: "claude-code",
      options: %{},
      runtime: runtime,
      launch_plan: plan
    }

    config =
      ContainerManager.build_container_config(%{id: "job-test"},
        worktree_path: "/repo/.omashiki-worktrees/job-test",
        repo_root: "/repo",
        host_uid: 1000,
        host_gid: 1000,
        harness_profile: profile,
        launch_plan: plan,
        harness_env: [],
        network_mode: "none"
      )

    assert config["Labels"]["omashiki.protocol"] == "cli"
    refute Map.has_key?(config, "ExposedPorts")
    refute Map.has_key?(config["HostConfig"], "PortBindings")
  end
end
