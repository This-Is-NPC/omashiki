defmodule Omashiki.Runtime.ContainerManagerTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Harness.LaunchPlan
  alias Omashiki.Plugin.Preset
  alias Omashiki.Runtime.Spec

  setup do
    Config.reset!()

    on_exit(fn -> Config.reset!() end)

    :ok
  end

  test "boot checks only handlers selected by active environments" do
    :ok = Config.load_map!(runtime_config())
    owner = self()

    checker = fn handlers ->
      send(owner, {:runtime_handlers_checked, handlers})
      :ok
    end

    assert {:ok, %{available: true}} =
             ContainerManager.init(availability: true, handler_checker: checker)

    assert_receive {:runtime_handlers_checked, ["runc"]}
  end

  test "boot stops clearly when a selected handler is unavailable" do
    :ok = Config.load_map!(runtime_config())

    checker = fn ["runc"] -> {:error, {:missing_runtime_handlers, ["runc"], ["kata"]}} end

    assert {:stop,
            {:runtime_handlers_unavailable, {:missing_runtime_handlers, ["runc"], ["kata"]}}} =
             ContainerManager.init(availability: true, handler_checker: checker)
  end

  test "provision checks the selected runtime handler before dispatch" do
    owner = self()

    checker = fn handlers ->
      send(owner, {:runtime_handlers_checked, handlers})
      :ok
    end

    {:ok, manager} =
      ContainerManager.start_link(
        name: nil,
        availability: true,
        operations: __MODULE__.BlockingOperations,
        handler_checker: checker
      )

    runtime = runtime("kata")

    task =
      Task.async(fn ->
        GenServer.call(
          manager,
          {:provision_for_job, %{id: "job"}, %{id: "attempt"}, %{owner: owner, runtime: runtime},
           []},
          2_000
        )
      end)

    assert_receive {:runtime_handlers_checked, []}
    assert_receive {:runtime_handlers_checked, ["kata"]}
    assert_receive {:docker_operation_started, "attempt", worker}
    send(worker, :continue)
    assert Task.await(task, 1_000) == {:ok, %{sandbox_id: "attempt"}}
  end

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
        operations: __MODULE__.BlockingOperations
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
        internal_port: nil,
        runtime_handler: "runc"
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
        internal_port: 4096,
        runtime_handler: "runc"
      )

    assert config["PortBindings"] == %{
             "4096/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "14096"}]
           }
  end

  test "container config recognizes a CLI plan with serializable string transport keys" do
    runtime = %Spec{
      name: "docker.runc.debian",
      backend: "docker",
      handler: "runc",
      distribution: "debian",
      plugin: "claude-code",
      image: "agent-claude"
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
      adapter: Omashiki.Plugin.Interpreter,
      plugin: "claude-code",
      options: %{},
      runtime: runtime,
      launch_plan: plan,
      manifest: nil
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
        network_mode: "none",
        job: %{correlation_id: "correlation-test"}
      )

    assert config["Labels"]["omashiki.protocol"] == "cli"
    assert config["Labels"]["omashiki.correlation_id"] == "correlation-test"
    assert config["Labels"]["omashiki.runtime"] == "docker.runc.debian"
    assert config["Labels"]["omashiki.runtime_handler"] == "runc"
    assert config["Labels"]["omashiki.backend"] == "docker"
    assert config["Labels"]["omashiki.distribution"] == "debian"
    refute Map.has_key?(config["Labels"], "omashiki.isolation")
    refute Map.has_key?(config, "ExposedPorts")
    refute Map.has_key?(config["HostConfig"], "PortBindings")
    refute Map.has_key?(config["HostConfig"], "Runtime")
  end

  test "container config labels and selects the kata handler" do
    runtime = %Spec{
      name: "docker.kata.debian",
      backend: "docker",
      handler: "kata",
      distribution: "debian",
      plugin: "claude-code",
      image: "agent-claude"
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
      adapter: Omashiki.Plugin.Interpreter,
      plugin: "claude-code",
      options: %{},
      runtime: runtime,
      launch_plan: plan,
      manifest: nil
    }

    config =
      ContainerManager.build_container_config(%{id: "job-kata"},
        worktree_path: "/repo/.omashiki-worktrees/job-kata",
        repo_root: "/repo",
        host_uid: 1000,
        host_gid: 1000,
        preset: profile,
        launch_plan: plan,
        harness_env: [],
        network_mode: "none"
      )

    assert config["Labels"]["omashiki.runtime"] == "docker.kata.debian"
    assert config["Labels"]["omashiki.runtime_handler"] == "kata"
    assert config["HostConfig"]["Runtime"] == "kata"
    refute Map.has_key?(config["Labels"], "omashiki.correlation_id")
  end

  test "kata transport selects the Docker Engine runtime handler" do
    config =
      ContainerManager.build_host_config(
        "/repo",
        "/repo/worktree",
        nil,
        1000,
        1000,
        network_mode: "none",
        runtime_handler: "kata"
      )

    assert config["Runtime"] == "kata"
  end

  test "unsupported Docker runtime handlers fail before container creation" do
    assert_raise ArgumentError, ~r/unsupported Docker runtime handler "gvisor"/, fn ->
      ContainerManager.build_host_config(
        "/repo",
        "/repo/worktree",
        nil,
        1000,
        1000,
        network_mode: "none",
        runtime_handler: "gvisor"
      )
    end
  end

  test "Docker runtime handler is required" do
    assert_raise ArgumentError, "Docker runtime handler is required", fn ->
      ContainerManager.build_host_config(
        "/repo",
        "/repo/worktree",
        nil,
        1000,
        1000,
        network_mode: "none",
        runtime_handler: nil
      )
    end
  end

  defp runtime(handler) do
    %Spec{
      name: "docker.#{handler}.debian",
      backend: "docker",
      handler: handler,
      distribution: "debian",
      plugin: "opencode",
      image: "agent"
    }
  end

  defp runtime_config do
    %{
      "repositories" => %{},
      "presets" => %{"opencode" => %{"plugin" => "opencode", "options" => %{}}},
      "runtimes" => %{
        "docker" => %{
          "runc" => %{"debian" => %{"images" => %{"opencode" => "agent-runc"}}},
          "kata" => %{"debian" => %{"images" => %{"opencode" => "agent-kata"}}}
        }
      },
      "environments" => %{
        "opencode" => %{
          "runtime" => "docker.runc.debian",
          "sink" => "git",
          "packages" => [],
          "preset" => "opencode",
          "executables" => ["git"],
          "credentials" => [],
          "caches" => [],
          "timeout_ms" => 120_000,
          "network" => "none",
          "mounts" => [],
          "pre_steps" => [],
          "post_steps" => [],
          "policy" => %{"mode" => "off"},
          "resources" => %{"cpus" => 1.0, "memory" => "128MB", "pids" => 128}
        }
      }
    }
  end
end
