defmodule Omashiki.Integration.QueueRealProviderE2ETest do
  @moduledoc """
  Real queue-only smoke test through admission, Oban, a configured CLI/HTTP
  harness, and Git.

  Run from the repository root with `mise run e2e:overture`. The preparation
  task recreates the ignored nested repository and stages read-only snapshots
  of the host OpenCode configuration and authentication.
  """

  use OmashikiWeb.ConnCase, async: false

  @moduletag timeout: 900_000
  @moduletag ownership_timeout: 900_000

  alias Omashiki.Config
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

  defp run_provider(
         %{conn: conn, repo: repo, token_plaintext: token},
         harness,
         environment,
         idempotency_key
       ) do
    image =
      if harness == "opencode", do: "omashiki/agent:latest", else: "omashiki/agent-claude:latest"

    assert {_, 0} = System.cmd("docker", ["image", "inspect", image])

    request = %{
      "schema_version" => 1,
      "idempotency_key" => idempotency_key,
      "correlation_id" => "overture-real-provider-e2e-#{harness}",
      "repo" => "overture",
      "environment" => environment,
      "payload" => %{"instruction" => @instructions},
      "priority" => 0
    }

    admitted = post(conn, "/api/v1/jobs", request)
    assert admitted.status == 202
    job_id = json_response(admitted, 202)["data"]["id"]

    expected_worktree = Path.join(repo, ".omashiki-worktrees/job-#{job_id}")
    assert expected_worktree == Path.expand(expected_worktree)

    drained = Oban.drain_queue(queue: :scheduler, with_recursion: true, with_scheduled: true)
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
    assert result["branch"] == "omashiki/job-#{job_id}"
    branch = result["branch"]

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
end
