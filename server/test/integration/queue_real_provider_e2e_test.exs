defmodule Omashiki.Integration.QueueRealProviderE2ETest do
  @moduledoc """
  Real queue-only smoke test through admission, Oban, a configured CLI/HTTP
  harness, and Git.

  Run from the repository root with `mise run e2e:overture`. The preparation
  task recreates the ignored nested repository and stages read-only snapshots
  of the host OpenCode configuration and authentication.

  The jcode case stages no snapshot: it holds no provider credential at all and
  reaches the model through the gateway, so it needs
  `OMASHIKI_LOCAL_LLM_BASE_URL` pointing at the local OpenAI-compatible server.
  """

  use OmashikiWeb.ConnCase, async: false

  @test_timeout_slack_ms 120_000
  @runtime_probe_timeout_ms 120_000
  @max_runtime_timeout_ms 1_800_000

  # Kata's generated environment is the slowest matrix member; keep ExUnit's
  # process and sandbox ownership limits above that environment deadline.
  @moduletag timeout: @max_runtime_timeout_ms + @test_timeout_slack_ms
  @moduletag ownership_timeout: @max_runtime_timeout_ms + @test_timeout_slack_ms

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt, JobStep}
  alias Omashiki.Repo

  @instructions """
  Create a Python file named hello.py at the repository root. It must print
  exactly `Hello, World!` followed by a newline when run with `python3 hello.py`.
  Commit the file with a concise commit message. Do not create or modify any
  other file.
  """

  setup do
    root = Path.expand("../../..", __DIR__)
    repo = Path.join(root, "overture")
    config = Path.join(root, "omashiki.e2e.toml")

    assert File.regular?(config), "run `mise run e2e:prepare` first"
    assert File.dir?(Path.join(repo, ".git")), "overture fixture is not initialized"
    Config.load!(config)
    assert {:ok, _capacity} = Jobs.sync_capacity()

    {:ok, root: root, repo: repo}
  end

  @tag :real_opencode
  test "OpenCode creates and executes committed Python hello world", ctx do
    run_provider(ctx, "opencode", "e2e-opencode", "overture-hello-world-opencode")
  end

  @tag :real_claude
  test "Claude Code creates and executes committed Python hello world", ctx do
    run_provider(ctx, "claude-code", "e2e-claude", "overture-hello-world-claude")
  end

  # jcode has no host-auth route: it reaches the model only through the gateway,
  # which forwards to the local OpenAI-compatible server declared by
  # `credentials.local-llm`. `mise run e2e:overture:jcode` is what stages it.
  @tag :real_jcode
  test "jcode creates and executes committed Python hello world", ctx do
    run_provider(ctx, "jcode", "e2e-jcode", "overture-hello-world-jcode")
  end

  defp run_provider(
         %{conn: conn, repo: repo, token_plaintext: token},
         harness,
         environment,
         idempotency_key
       ) do
    %{runtime: %{handler: runtime_handler, image: image}, timeout_ms: timeout_ms} =
      Config.get_environment(environment)

    assert {_, 0} = System.cmd("docker", ["image", "inspect", image])

    request = %{
      "schema_version" => 1,
      "idempotency_key" => idempotency_key,
      "correlation_id" => "overture-real-provider-e2e-#{harness}",
      "repo" => "overture",
      "environment" => environment,
      "payload" => %{"instruction" => @instructions, "title" => "e2e-hello-world"},
      "priority" => 0
    }

    admitted = post(conn, "/api/v1/jobs", request)
    assert admitted.status == 202
    job_id = json_response(admitted, 202)["data"]["id"]

    task_branch = "e2e-hello-world"
    expected_worktree = Path.join(repo, ".omashiki-worktrees/#{task_branch}-run-001")
    assert expected_worktree == Path.expand(expected_worktree)

    attempt = Repo.get_by!(JobAttempt, job_id: job_id)
    scope_id = "job-#{attempt.id}"

    # Cleanup removes the container before the result is returned. Drain in a
    # linked task and inspect the running container so this proves Docker used
    # the selected HostConfig runtime rather than a post-cleanup label.
    drain_task =
      Task.async(fn ->
        Oban.drain_queue(queue: :scheduler, with_recursion: true, with_scheduled: true)
      end)

    execution_deadline = System.monotonic_time(:millisecond) + timeout_ms + @test_timeout_slack_ms

    probe_deadline =
      min(execution_deadline, System.monotonic_time(:millisecond) + @runtime_probe_timeout_ms)

    drained =
      drain_and_inspect_runtime!(
        drain_task,
        scope_id,
        runtime_handler,
        probe_deadline,
        execution_deadline,
        job_id
      )

    assert drained.failure == 0

    assert drained.success == 1,
           inspect(%{
             drained: drained,
             job: Repo.get(Job, job_id),
             attempts: Repo.all(JobAttempt),
             steps: Repo.all(JobStep),
             oban: Repo.all(Oban.Job) |> List.last()
           })

    result_conn = get(authenticated_conn(token), "/api/v1/jobs/#{job_id}/result")
    assert result_conn.status == 200
    result = json_response(result_conn, 200)["data"]

    assert result["status"] == "succeeded",
           inspect(%{
             result: result,
             job: Repo.get(Job, job_id),
             attempts: Repo.all(JobAttempt),
             steps: Repo.all(JobStep),
             oban: Repo.all(Oban.Job) |> List.last()
           })

    assert result["worktree_clean"] == true
    assert result["base_sha"] != result["head_sha"]
    assert result["branch"] == task_branch
    branch = task_branch

    assert git!(repo, ["rev-parse", branch]) == result["head_sha"]
    assert git!(repo, ["show", "#{branch}:hello.py"]) =~ "Hello, World!"

    provision = Repo.get_by!(JobStep, key: "provision")
    cleanup = Repo.get_by!(JobStep, key: "cleanup")
    assert provision.output["worktree_path"] == expected_worktree
    assert cleanup.status == "succeeded", inspect(cleanup)
    refute File.exists?(expected_worktree)
    assert_all_worktrees_internal!(repo)

    git!(repo, ["checkout", "-q", branch])
    assert {"Hello, World!\n", 0} = System.cmd("python3", [Path.join(repo, "hello.py")])
  end

  defp authenticated_conn(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  defp assert_runtime_while_alive!(scope_id, expected_handler, deadline, job_id) do
    case running_container_runtime(scope_id) do
      {:ok, runtime} ->
        assert_runtime_representation!(runtime, expected_handler)

      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          assert_runtime_while_alive!(scope_id, expected_handler, deadline, job_id)
        else
          flunk(
            "no running Docker container found for #{scope_id} before cleanup: " <>
              inspect(runtime_probe_diagnostics(job_id))
          )
        end

      {:error, output} ->
        flunk("Docker runtime probe failed for #{scope_id}: #{output}")
    end
  end

  defp drain_and_inspect_runtime!(
         drain_task,
         scope_id,
         runtime_handler,
         probe_deadline,
         execution_deadline,
         job_id
       ) do
    try do
      assert_runtime_while_alive!(scope_id, runtime_handler, probe_deadline, job_id)
      remaining = max(execution_deadline - System.monotonic_time(:millisecond), 1)
      drained = Task.await(drain_task, remaining)
      assert_no_container!(scope_id)
      drained
    rescue
      error ->
        stop_and_cleanup!(drain_task, scope_id)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        stop_and_cleanup!(drain_task, scope_id)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if Process.alive?(drain_task.pid), do: Task.shutdown(drain_task, :brutal_kill)
    end
  end

  defp runtime_probe_diagnostics(job_id) do
    %{
      job: Repo.get(Job, job_id),
      attempts: Repo.all(JobAttempt),
      steps: Repo.all(JobStep),
      oban: Repo.all(Oban.Job) |> List.last()
    }
  end

  defp stop_and_cleanup!(drain_task, scope_id) do
    if Process.alive?(drain_task.pid), do: Task.shutdown(drain_task, :brutal_kill)

    assert :ok = Omashiki.Runtime.ContainerManager.cancel_scope(scope_id)
    assert_no_container!(scope_id)
  end

  defp assert_runtime_representation!("runc", "runc"), do: :ok

  defp assert_runtime_representation!("", "runc") do
    case docker_default_runtime() do
      {:ok, "runc"} ->
        :ok

      {:ok, runtime} ->
        flunk("Docker HostConfig.Runtime was empty but daemon default is #{inspect(runtime)}")

      {:error, output} ->
        flunk("could not verify Docker default runtime: #{output}")
    end
  end

  defp assert_runtime_representation!("kata", "kata"), do: :ok

  defp assert_runtime_representation!(runtime, expected_handler) do
    flunk("Docker selected runtime #{inspect(runtime)}, expected #{inspect(expected_handler)}")
  end

  defp docker_default_runtime do
    case System.cmd("docker", ["info", "--format", "{{.DefaultRuntime}}"], stderr_to_stdout: true) do
      {runtime, 0} -> {:ok, String.trim(runtime)}
      {output, status} -> {:error, "docker info exited #{status}: #{output}"}
    end
  end

  defp running_container_runtime(scope_id) do
    filter = "label=omashiki.job_scope_id=#{scope_id}"

    case System.cmd("docker", ["ps", "-q", "--no-trunc", "--filter", filter],
           stderr_to_stdout: true
         ) do
      {ids, 0} ->
        case ids |> String.trim() |> String.split("\n", trim: true) |> List.first() do
          nil ->
            :retry

          container_id ->
            case System.cmd(
                   "docker",
                   [
                     "inspect",
                     "--format",
                     "{{.State.Running}}\t{{.HostConfig.Runtime}}",
                     container_id
                   ],
                   stderr_to_stdout: true
                 ) do
              {"true\t" <> runtime, 0} ->
                {:ok, String.trim(runtime)}

              {_, 0} ->
                :retry

              {output, status} ->
                if missing_container?(output),
                  do: :retry,
                  else: {:error, "inspect exited #{status}: #{output}"}
            end
        end

      {output, status} ->
        {:error, "ps exited #{status}: #{output}"}
    end
  end

  defp assert_all_worktrees_internal!(repo) do
    root = Path.join(repo, ".omashiki-worktrees") |> Path.expand()

    repo
    |> git!(["worktree", "list", "--porcelain"])
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.each(fn "worktree " <> path ->
      expanded = Path.expand(path)
      assert expanded == Path.expand(repo) or String.starts_with?(expanded, root <> "/")
    end)
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp missing_container?(output) do
    downcased = String.downcase(output)

    Enum.any?(
      ["no such object", "no such container", "not found"],
      &String.contains?(downcased, &1)
    )
  end

  defp assert_no_container!(scope_id) do
    filter = "label=omashiki.job_scope_id=#{scope_id}"

    case System.cmd("docker", ["ps", "-aq", "--no-trunc", "--filter", filter],
           stderr_to_stdout: true
         ) do
      {ids, 0} ->
        assert String.trim(ids) == "", "Docker container still exists for #{scope_id}: #{ids}"

      {output, status} ->
        flunk("Docker cleanup probe exited #{status} for #{scope_id}: #{output}")
    end
  end
end
