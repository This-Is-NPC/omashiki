defmodule Omashiki.Runtime.AttemptTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Runtime.AttemptSupervisor

  @owner_key {__MODULE__, :owner}
  @harness_key {__MODULE__, :harness}

  defmodule Container do
    def provision(_job, attempt, _environment, _opts) do
      send(owner(), {:provisioning, attempt.id, self()})

      receive do
        :continue -> {:ok, %{id: "container-#{attempt.id}", host: "127.0.0.1", port: 4096}}
      end
    end

    def exec(_container, _argv, _timeout_ms), do: {:ok, %{stdout: "", exit_code: 0}}

    def finalize(_container, _job, _opts) do
      {:ok,
       %{
         branch: "omashiki/test",
         base_sha: String.duplicate("a", 40),
         head_sha: String.duplicate("b", 40),
         worktree_clean: true
       }}
    end

    def destroy(container) do
      send(owner(), {:destroyed, container.id})
      :ok
    end

    def cancel_scope(scope_id) do
      send(owner(), {:cancel_scope, scope_id})

      case :persistent_term.get(Omashiki.Runtime.AttemptTest.harness_key(), nil) do
        pid when is_pid(pid) -> send(pid, :runtime_cancelled)
        _ -> :ok
      end

      :ok
    end

    defp owner, do: :persistent_term.get(Omashiki.Runtime.AttemptTest.owner_key())
  end

  defmodule ImmediateHarness do
    def invoke(_invocation, _context), do: {:ok, %{assistant_text: "ok"}}
  end

  defmodule BlockingHarness do
    def invoke(_invocation, _context) do
      :persistent_term.put(Omashiki.Runtime.AttemptTest.harness_key(), self())

      send(
        :persistent_term.get(Omashiki.Runtime.AttemptTest.owner_key()),
        {:harness_started, self()}
      )

      receive do
        :runtime_cancelled -> {:error, :runtime_cancelled}
      end
    end
  end

  def owner_key, do: @owner_key
  def harness_key, do: @harness_key

  setup do
    :persistent_term.put(@owner_key, self())
    :persistent_term.erase(@harness_key)

    root = Path.join(System.tmp_dir!(), "omashiki-attempt-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q", "-b", "main"])

    {_, 0} =
      System.cmd("git", ["-C", repo_path, "commit", "--allow-empty", "-q", "-m", "init"],
        env: git_identity()
      )

    Config.load_map!(config(), path: Path.join(root, "omashiki.toml"))
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    on_exit(fn ->
      :persistent_term.erase(@owner_key)
      :persistent_term.erase(@harness_key)
      File.rm_rf!(root)
    end)

    {:ok, token: token}
  end

  test "runs independent attempts concurrently", %{token: token} do
    attempts =
      Enum.map(1..2, fn number ->
        {:ok, job} = Jobs.Admission.admit(token, request("parallel-#{number}"))
        {:ok, attempt} = Jobs.claim(job, "parallel-runner-#{number}")
        attempt
      end)

    tasks =
      Enum.map(attempts, fn attempt ->
        Task.async(fn ->
          AttemptSupervisor.run(attempt,
            container: Container,
            adapter: ImmediateHarness,
            pre_steps: [],
            post_steps: []
          )
        end)
      end)

    workers =
      Enum.map(attempts, fn attempt ->
        attempt_id = attempt.id
        assert_receive {:provisioning, ^attempt_id, worker}, 1_000
        worker
      end)

    Enum.each(workers, &send(&1, :continue))

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %{status: "succeeded"}}, Task.await(task, 2_000))
           end)
  end

  test "durable cancellation interrupts the active runtime and preserves cancelled", %{
    token: token
  } do
    {:ok, job} = Jobs.Admission.admit(token, request("cancel-running"))
    {:ok, attempt} = Jobs.claim(job, "cancel-runner")

    task =
      Task.async(fn ->
        AttemptSupervisor.run(attempt,
          container: Container,
          adapter: BlockingHarness,
          pre_steps: [],
          post_steps: []
        )
      end)

    attempt_id = attempt.id
    assert_receive {:provisioning, ^attempt_id, provisioner}, 1_000
    send(provisioner, :continue)
    assert_receive {:harness_started, _harness}, 1_000

    assert {:ok, %{status: "cancelled"}} = Jobs.cancel(job)
    assert_receive {:cancel_scope, "job-" <> scope_attempt_id}, 1_000
    assert scope_attempt_id == attempt.id
    assert_receive {:destroyed, "container-" <> container_attempt_id}, 1_000
    assert container_attempt_id == attempt.id
    assert {:ok, %{status: "cancelled"}} = Task.await(task, 2_000)
  end

  defp config do
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
          "preset" => "opencode",
          "executables" => ["git"],
          "timeout_ms" => 1_000,
          "caches" => [],
          "mounts" => [],
          "pre_steps" => [],
          "post_steps" => [],
          "policy" => %{"mode" => "off"},
          "network" => "none",
          "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
        }
      },
      "limits" => %{}
    }
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

  defp git_identity do
    [
      {"GIT_AUTHOR_NAME", "Attempt Test"},
      {"GIT_AUTHOR_EMAIL", "attempt@example.test"},
      {"GIT_COMMITTER_NAME", "Attempt Test"},
      {"GIT_COMMITTER_EMAIL", "attempt@example.test"}
    ]
  end
end
