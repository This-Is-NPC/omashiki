defmodule Omashiki.Jobs.RunnerTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{JobStep, Runner}
  alias Omashiki.Repo

  defmodule FakeContainer do
    def provision(_job, _attempt, _environment, _opts),
      do: {:ok, %{id: "fake-container", host: "127.0.0.1", port: 4096}}

    def exec(_container, argv, _timeout_ms) do
      if "fail" in argv,
        do: {:error, {:exit_status, 7, "failed\n"}},
        else: {:ok, %{exit_status: 0, output: Enum.join(argv, " ")}}
    end

    def finalize(_container, _job, _opts),
      do:
        {:ok,
         %{
           branch: "jobs/fake",
           base_sha: String.duplicate("a", 40),
           head_sha: String.duplicate("b", 40),
           worktree_clean: true
         }}

    def destroy(container) do
      send(self(), {:destroyed, container.id})
      :ok
    end
  end

  defmodule FakeHarness do
    def invoke(invocation, _context),
      do: {:ok, %Omashiki.Harness.Result{assistant_text: invocation.instruction || "ok"}}
  end

  defmodule CrashingHarness do
    def invoke(_invocation, _context), do: raise("simulated harness crash")
  end

  defmodule SlowHarness do
    def invoke(invocation, _context) do
      Process.sleep(180)
      {:ok, %{assistant_text: invocation.instruction || "ok"}}
    end
  end

  defmodule ProvisionFailureContainer do
    def provision(_job, _attempt, _environment, _opts), do: {:error, :docker_provision_failed}
    def exec(_container, _argv, _timeout_ms), do: {:error, :not_reached}
    def finalize(_container, _job, _opts), do: {:error, :not_reached}
    def destroy(_container), do: :ok
  end

  defmodule FinalizeFailureContainer do
    def provision(_job, _attempt, _environment, _opts),
      do: {:ok, %{id: "finalize-failure-container"}}

    def exec(_container, _argv, _timeout_ms),
      do: {:ok, %{exit_status: 0, output: "ok"}}

    def finalize(_container, _job, _opts), do: {:error, :git_commit_failed}

    def destroy(container) do
      send(self(), {:destroyed, container.id})
      :ok
    end
  end

  defmodule CleanupFailureContainer do
    def provision(_job, _attempt, _environment, _opts),
      do: {:ok, %{id: "cleanup-failure-container"}}

    def exec(_container, _argv, _timeout_ms),
      do: {:ok, %{exit_status: 0, output: "ok"}}

    def finalize(_container, _job, _opts),
      do:
        {:ok,
         %{
           branch: "jobs/cleanup",
           base_sha: String.duplicate("a", 40),
           head_sha: String.duplicate("b", 40),
           worktree_clean: true
         }}

    def destroy(_container), do: {:error, :cleanup_failed}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-runner-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "presets" => %{
          "opencode" => %{"plugin" => "opencode", "options" => %{}}
        },
        "environments" => %{
          "safe" => %{
            "isolation" => "docker",
          "image" => "omashiki/agent:latest",
          "sink" => "git",
          "packages" => [],
          "preset" => "opencode",
            "executables" => ["git"],
            "timeout_ms" => 1_000,
            "caches" => [],
            "mounts" => [],
            "pre_steps" => [%{"argv" => ["git", "status"], "condition" => "always"}],
            "post_steps" => [
              %{"argv" => ["git", "status"], "condition" => "on_success"},
              %{"argv" => ["git", "status"], "condition" => "on_failure"},
              %{"argv" => ["git", "status"], "condition" => "always"}
            ],
            "policy" => %{"mode" => "off"},
            "network" => "none",
            "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
          }
        },
        "limits" => %{}
      },
      path: Path.join(root, "omashiki.toml")
    )

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, token: token}
  end

  test "runs one attempt in order and persists step evidence", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("success"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, completed} =
             Runner.run(attempt, container: FakeContainer, adapter: FakeHarness)

    assert completed.status == "succeeded"

    steps = Repo.all(from(s in JobStep, where: s.attempt_id == ^attempt.id, order_by: s.sequence))

    assert Enum.map(steps, &{&1.key, &1.status}) == [
             {"provision", "succeeded"},
             {"pre-1", "succeeded"},
             {"preset", "succeeded"},
             {"post-1", "succeeded"},
             {"post-2", "skipped"},
             {"post-3", "succeeded"},
             {"finalization", "succeeded"},
             {"cleanup", "succeeded"}
           ]

    assert Enum.all?(steps, &(&1.started_at && &1.finished_at))
    assert Enum.at(steps, 1).input["argv"] == ["git", "status"]
    assert_receive {:destroyed, "fake-container"}
  end

  test "assigns contiguous step sequences without pre or post steps", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("no-command-steps"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, completed} =
             Runner.run(attempt,
               container: FakeContainer,
               adapter: FakeHarness,
               pre_steps: [],
               post_steps: []
             )

    assert completed.status == "succeeded"

    steps = Repo.all(from(s in JobStep, where: s.attempt_id == ^attempt.id, order_by: s.sequence))

    assert Enum.map(steps, &{&1.sequence, &1.key}) == [
             {1, "provision"},
             {2, "preset"},
             {3, "finalization"},
             {4, "cleanup"}
           ]
  end

  test "renews the lease while a harness turn is running", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("slow-turn"))
    {:ok, attempt} = Jobs.claim(job, "runner-test", lease_ms: 100)

    assert {:ok, completed} =
             Runner.run(attempt,
               container: FakeContainer,
               adapter: SlowHarness,
               heartbeat_interval_ms: 10,
               pre_steps: [],
               post_steps: []
             )

    assert completed.status == "succeeded"
  end

  test "runs failure post steps and cleanup after a failed pre-step", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("failure"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, failed} =
             Runner.run(attempt,
               container: FakeContainer,
               adapter: FakeHarness,
               pre_steps: [%{"argv" => ["git", "fail"], "condition" => "always"}]
             )

    assert failed.status == "failed"

    statuses =
      Repo.all(from(s in JobStep, where: s.attempt_id == ^attempt.id, order_by: s.sequence))

    assert Enum.map(statuses, &{&1.key, &1.status}) == [
             {"provision", "succeeded"},
             {"pre-1", "failed"},
             {"preset", "skipped"},
             {"post-1", "skipped"},
             {"post-2", "succeeded"},
             {"post-3", "succeeded"},
             {"finalization", "succeeded"},
             {"cleanup", "succeeded"}
           ]

    assert_receive {:destroyed, "fake-container"}
  end

  test "rejects an unsafe argv before a container boundary" do
    assert {:error, {:invalid_argv, _}} =
             Runner.validate_argv(["sh", "-c", "true"], ["sh"])
  end

  test "turn crashes still finalize the attempt and clean the container", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("crash"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, failed} =
             Runner.run(attempt, container: FakeContainer, adapter: CrashingHarness)

    assert failed.status == "failed"
    assert_receive {:destroyed, "fake-container"}

    cleanup =
      Repo.one!(from(s in JobStep, where: s.attempt_id == ^attempt.id and s.key == "cleanup"))

    assert cleanup.status == "succeeded"
  end

  test "Docker provision failure still reaches one terminal effect", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("provision-failure"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, failed} =
             Runner.run(attempt, container: ProvisionFailureContainer, adapter: FakeHarness)

    assert failed.status == "failed"
    assert capacity_row().active == 0
    assert Repo.aggregate(JobStep, :count, :id) == 8
  end

  test "Git finalization failure does not duplicate terminal completion", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("finalize-failure"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, failed} =
             Runner.run(attempt, container: FinalizeFailureContainer, adapter: FakeHarness)

    assert failed.status == "failed"
    assert_receive {:destroyed, "finalize-failure-container"}

    assert Repo.aggregate(from(s in JobStep, where: s.attempt_id == ^attempt.id), :count, :id) ==
             8
  end

  test "cleanup failure does not reopen a committed terminal job", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("cleanup-failure"))
    {:ok, attempt} = Jobs.claim(job, "runner-test")

    assert {:ok, succeeded} =
             Runner.run(attempt, container: CleanupFailureContainer, adapter: FakeHarness)

    assert succeeded.status == "succeeded"

    cleanup =
      Repo.one!(from(s in JobStep, where: s.attempt_id == ^attempt.id and s.key == "cleanup"))

    assert cleanup.status == "failed"

    assert Repo.aggregate(
             from(e in Omashiki.Jobs.JobEvent, where: e.job_id == ^job.id),
             :count,
             :event_id
           ) == 4
  end

  defp request(key) do
    %{
      "schema_version" => 1,
      "idempotency_key" => key,
      "correlation_id" => "correlation-#{key}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{"instruction" => "hello"},
      "priority" => 0
    }
  end
end
