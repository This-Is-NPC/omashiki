defmodule Omashiki.Runtime.ContainerManagerTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Harness.LaunchPlan
  alias Omashiki.Plugin.Preset
  alias Omashiki.Runtime.Spec
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtimes.CacheGroup
  alias Omashiki.SupplyChain.Policy

  setup do
    on_exit(fn -> Application.delete_env(:omashiki, :manager_url) end)
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


  describe "supply_chain_delivery data plane" do
    test "embedded allowlist binds host socket when manager_url is unset" do
      Application.delete_env(:omashiki, :manager_url)

      delivery = supply_chain_delivery_fixture()

      assert Enum.any?(delivery.env, &String.starts_with?(&1, "OMASHIKI_HOST_SOCKET="))
      assert Enum.any?(delivery.binds, &String.contains?(&1, "host.sock"))

      npm = registry_env(delivery.env)
      assert npm =~ "127.0.0.1:8080"
      refute npm =~ "manager.test"
    end

    test "remote manager_url uses HTTP gateway without host socket binds" do
      Application.put_env(:omashiki, :manager_url, "http://manager.test:9090/")

      delivery = supply_chain_delivery_fixture()

      refute Enum.any?(delivery.env, &String.starts_with?(&1, "OMASHIKI_HOST_SOCKET="))
      refute Enum.any?(delivery.binds, &String.contains?(&1, "host.sock"))

      npm = registry_env(delivery.env)
      assert npm =~ "manager.test:9090"
      assert npm =~ "/api/v1/supply-chain/deps/npm/"
    end

    test "remote supply chain mints token from in-memory job without Repo lookup" do
      Application.put_env(:omashiki, :manager_url, "http://manager.test:9090/")

      job = %Job{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        admitted_environment_digest: String.duplicate("c", 64),
        status: "running"
      }

      policy =
        Policy.parse!(%{"mode" => "allowlist", "packages" => %{"npm" => %{"left-pad" => "1.0.0"}}})

      group = %CacheGroup{name: "deps", policy: policy}

      delivery = ContainerManager.supply_chain_delivery("scope-1", job, [group], 1000, 1000)

      npm = registry_env(delivery.env)
      assert npm =~ "manager.test:9090"
      assert npm =~ "/api/v1/supply-chain/deps/npm/"
      refute npm =~ "npm//"
    end
  end

  describe "active_job_scope_ids/0" do
    alias Omashiki.Jobs.JobAttempt

    setup do
      original = Application.get_env(:omashiki, :boot_role)

      on_exit(fn ->
        if original,
          do: Application.put_env(:omashiki, :boot_role, original),
          else: Application.delete_env(:omashiki, :boot_role)
      end)

      :ok
    end
    test "returns [] when boot_role is :worker without querying Repo" do
      Application.put_env(:omashiki, :boot_role, :worker)

      assert ContainerManager.active_job_scope_ids() == []
    end

    test "returns active attempt scope ids when Repo is available" do
      Application.put_env(:omashiki, :boot_role, :embedded)
      job = job_fixture()
      now = DateTime.utc_now(:microsecond)

      attempt =
        %JobAttempt{}
        |> JobAttempt.changeset(%{
          job_id: job.id,
          number: 1,
          status: "running",
          lease_token: "lease",
          lease_expires_at: DateTime.add(now, 60, :second),
          heartbeat_at: now,
          claimed_at: now,
          capacity_reserved: true,
          started_at: now
        })
        |> Repo.insert!()

      assert ContainerManager.active_job_scope_ids() == ["job-#{attempt.id}"]
    end
  end

  describe "harness_egress_delivery/4" do
    test "remote manager egress uses HTTPS_PROXY without minting local claims" do
      manager_url = "http://manager.test:4013"
      job = %Job{id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate(), status: "running"}

      supply_env = ["npm_config_registry=http://manager.test:4013/api/v1/supply-chain/deps/npm/"]

      delivery =
        ContainerManager.harness_egress_delivery(:engine, supply_env, job, manager_url)

      assert delivery.labels == %{"omashiki.llm_egress" => "restricted"}

      https_proxy =
        Enum.find_value(delivery.env, fn entry ->
          case String.split(entry, "=", parts: 2) do
            ["HTTPS_PROXY", url] -> url
            _ -> nil
          end
        end)

      assert https_proxy == manager_url
      refute Enum.any?(delivery.env, &String.starts_with?(&1, "OMASHIKI_LLM_EGRESS_TOKEN="))
      refute Enum.any?(delivery.env, &String.starts_with?(&1, "OMASHIKI_LLM_EGRESS_SOCKET="))
      assert delivery.binds == []
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
  defp supply_chain_delivery_fixture do
    job = job_fixture()
    policy = Policy.parse!(%{"mode" => "allowlist", "packages" => %{"npm" => %{"left-pad" => "1.0.0"}}})
    group = %CacheGroup{name: "deps", policy: policy}

    ContainerManager.supply_chain_delivery("scope-1", job, [group], 1000, 1000)
  end

  defp registry_env(env) do
    Enum.find_value(env, fn entry ->
      case String.split(entry, "=", parts: 2) do
        ["npm_config_registry", url] -> url
        _ -> nil
      end
    end)
  end

  defp job_fixture do
    user = user_fixture()

    attrs = %{
      user_id: user.id,
      schema_version: 1,
      idempotency_key: "cm-#{System.unique_integer([:positive])}",
      correlation_id: "cm-correlation",
      repository: "repo",
      environment: "isolated",
      payload: %{"ok" => true},
      payload_hash: String.duplicate("a", 64),
      admitted_repository: %{"path" => "/tmp/repo", "base_branch" => "main"},
      admitted_repository_digest: String.duplicate("b", 64),
      admitted_environment: %{"capabilities" => ["internal_read"]},
      admitted_environment_digest: String.duplicate("c", 64),
      admitted_plugin: %{
        "path" => "plugins/opencode.toml",
        "contents" => "",
        "digest" => String.duplicate("e", 64)
      },
      admitted_plugin_digest: String.duplicate("e", 64),
      registry_digest: String.duplicate("d", 64),
      queue: "default",
      priority: 0,
      status: "running",
      current_attempt: 1,
      queued_at: DateTime.utc_now(:microsecond),
      started_at: DateTime.utc_now(:microsecond)
    }

    Repo.insert!(Job.changeset(%Job{}, attrs))
  end
end
