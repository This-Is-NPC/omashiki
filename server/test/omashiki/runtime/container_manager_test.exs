defmodule Omashiki.Runtime.ContainerManagerTest do
  use ExUnit.Case, async: false

  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Harness.LaunchPlan
  alias Omashiki.Plugin.Preset
  alias Omashiki.Isolation

  defmodule BlockingOperations do
    def op_provision(_job, attempt, %{owner: owner}, _opts) do
      send(owner, {:docker_operation_started, attempt.id, self()})

      receive do
        :continue -> {:ok, %{sandbox_id: attempt.id}}
      end
    end

    def op_execute(_container_id, _argv, _timeout_ms), do: {:ok, %{stdout: "", exit_code: 0}}
    def op_remove(_container_id), do: :ok
    def op_cancel_scope(_scope_id), do: :ok
    def op_cleanup_orphans, do: {:ok, []}
    def op_fetch_logs(_container_id, _opts), do: {:ok, ""}
  end

  test "does not serialize independent blocking Docker operations" do
    owner = self()

    {:ok, manager} =
      ContainerManager.start_link(
        name: nil,
        availability: true,
        operations: BlockingOperations
      )

    calls =
      Enum.map(1..2, fn id ->
        Task.async(fn ->
          GenServer.call(
            manager,
            {:provision_for_job, %{id: id}, %{id: id}, %{owner: owner}, []},
            2_000
          )
        end)
      end)

    workers =
      Enum.map(1..2, fn id ->
        assert_receive {:docker_operation_started, ^id, worker}, 1_000
        worker
      end)

    Enum.each(workers, &send(&1, :continue))

    assert Enum.map(calls, &Task.await(&1, 1_000)) == [
             {:ok, %{sandbox_id: 1}},
             {:ok, %{sandbox_id: 2}}
           ]
  end

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
    runtime = %Isolation{
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

    profile = %Preset{
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
        preset: profile,
        launch_plan: plan,
        harness_env: [],
        network_mode: "none"
      )

    assert config["Labels"]["omashiki.protocol"] == "cli"
    refute Map.has_key?(config, "ExposedPorts")
    refute Map.has_key?(config["HostConfig"], "PortBindings")
  end
end
