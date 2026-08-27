defmodule Omashiki.Jobs.ParentCascadeTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt}
  alias Omashiki.Repo

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "omashiki-dependency-dag-#{System.unique_integer([:positive])}"
      )

    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo_path, "checkout", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", repo_path, "commit", "--allow-empty", "-m", "init"])

    load_config!(root)

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, token: token, repo_path: repo_path}
  end

  test "A and B must both succeed before C queues (A then B)", %{token: token} do
    assert {:ok, [a, b, c]} =
             Jobs.Admission.admit_batch(token, diamond_batch())

    assert a.status == "queued"
    assert b.status == "queued"
    assert c.status == "blocked"

    succeed_job!(a)
    assert Repo.get!(Job, c.id).status == "blocked"

    succeed_job!(b)
    assert Repo.get!(Job, c.id).status == "queued"
  end

  test "A and B must both succeed before C queues (B then A)", %{token: token} do
    assert {:ok, [a, b, c]} =
             Jobs.Admission.admit_batch(token, diamond_batch())

    succeed_job!(b)
    assert Repo.get!(Job, c.id).status == "blocked"

    succeed_job!(a)
    assert Repo.get!(Job, c.id).status == "queued"
  end

  test "cycle A->B->A at admission is rejected", %{token: token} do
    batch = %{
      "schema_version" => 1,
      "correlation_id" => "cycle-batch",
      "jobs" => [
        batch_job("a", [%{"ref" => "b"}]),
        batch_job("b", [%{"ref" => "a"}])
      ]
    }

    assert {:error, {:validation, errors}} = Jobs.Admission.admit_batch(token, batch)
    assert Enum.any?(errors, &(&1.field == "jobs.depends_on" and &1.code == "cycle"))
  end

  test "failed dependency with block edge keeps child blocked", %{token: token} do
    assert {:ok, [a, c]} =
             Jobs.Admission.admit_batch(
               token,
               %{
                 "schema_version" => 1,
                 "correlation_id" => "block-edge",
                 "jobs" => [
                   batch_job("a", []),
                   batch_job("c", [%{"ref" => "a", "on_failure" => "block"}])
                 ]
               }
             )

    fail_job!(a)

    assert Repo.get!(Job, c.id).status == "blocked"
  end

  test "failed dependency with cancel edge cancels child", %{token: token} do
    assert {:ok, [a, c]} =
             Jobs.Admission.admit_batch(
               token,
               %{
                 "schema_version" => 1,
                 "correlation_id" => "cancel-edge",
                 "jobs" => [
                   batch_job("a", []),
                   batch_job("c", [%{"ref" => "a", "on_failure" => "cancel"}])
                 ]
               }
             )

    fail_job!(a)

    cancelled = Repo.get!(Job, c.id)
    assert cancelled.status == "cancelled"
    assert cancelled.terminal_error["code"] == "dependency_failed"
    assert cancelled.terminal_error["details"]["dependency_job_id"] == a.id
  end

  test "failed dependency with proceed edge unblocks when remaining deps succeed", %{token: token} do
    assert {:ok, [a, b, c]} =
             Jobs.Admission.admit_batch(
               token,
               %{
                 "schema_version" => 1,
                 "correlation_id" => "proceed-edge",
                 "jobs" => [
                   batch_job("a", []),
                   batch_job("b", []),
                   batch_job("c", [
                     %{"ref" => "a", "on_failure" => "proceed"},
                     %{"ref" => "b"}
                   ])
                 ]
               }
             )

    fail_job!(a)
    assert Repo.get!(Job, c.id).status == "blocked"

    succeed_job!(b)

    queued = Repo.get!(Job, c.id)
    assert queued.status == "queued"
    assert length(queued.dependency_artifacts) == 2

    artifact_ids = MapSet.new(queued.dependency_artifacts, & &1["id"])
    assert MapSet.equal?(artifact_ids, MapSet.new([a.id, b.id]))
    assert Enum.find(queued.dependency_artifacts, &(&1["id"] == a.id))["status"] == "failed"
    assert Enum.find(queued.dependency_artifacts, &(&1["id"] == b.id))["status"] == "succeeded"
  end

  test "git child with base dependency uses dependency head sha", %{
    token: token,
    repo_path: repo_path
  } do
    parent_sha = commit_file!(repo_path, "parent.txt", "parent\n")

    assert {:ok, parent} =
             Jobs.Admission.admit(
               token,
               single_job("parent-root", %{"branch" => "feat-parent"})
             )

    succeed_job!(parent, head_sha: parent_sha)

    assert {:ok, child} =
             Jobs.Admission.admit(
               token,
               single_job("child-root", %{"branch" => "feat-child"}, [
                 %{"id" => parent.id}
               ])
               |> Map.put("base", "dependency:#{parent.id}")
             )

    assert child.status == "queued"

    {:ok, attempt} = Jobs.claim(child, "runner")

    assert {:ok, artifact} =
             Omashiki.Jobs.GitArtifact.provision_worktree(child, attempt, git_env: [])

    assert artifact.base_sha == parent_sha
  end

  test "git child defaults base to dependency and sees parent artifact in prompt", %{
    token: token,
    repo_path: repo_path
  } do
    parent_sha = commit_file!(repo_path, "parent-default.txt", "parent\n")

    assert {:ok, parent} =
             Jobs.Admission.admit(
               token,
               single_job("parent-default", %{"branch" => "feat-parent-default"})
             )

    succeed_job!(parent, head_sha: parent_sha)

    assert {:ok, child} =
             Jobs.Admission.admit(
               token,
               single_job("child-default", %{"branch" => "feat-child-default"}, [
                 %{"id" => parent.id}
               ])
             )

    assert child.status == "queued"
    assert child.admitted_repository["base"] == "dependency"
    assert length(child.dependency_artifacts) == 1
    assert hd(child.dependency_artifacts)["head_sha"] == parent_sha

    assert {:ok, prompt} = Omashiki.Harness.CliJson.prompt_for(child)
    assert prompt =~ parent_sha
    assert prompt =~ parent.id

    {:ok, attempt} = Jobs.claim(child, "runner")

    assert {:ok, artifact} =
             Omashiki.Jobs.GitArtifact.provision_worktree(child, attempt, git_env: [])

    assert artifact.base_sha == parent_sha
  end

  test "default git base uses first succeeded dependency head sha", %{
    token: token,
    repo_path: repo_path
  } do
    sha_b = commit_file!(repo_path, "b-default.txt", "b\n")

    assert {:ok, [a, b, c]} =
             Jobs.Admission.admit_batch(
               token,
               %{
                 "schema_version" => 1,
                 "correlation_id" => "default-base-proceed",
                 "jobs" => [
                   batch_job("a", []),
                   batch_job("b", []),
                   batch_job("c", [
                     %{"ref" => "a", "on_failure" => "proceed"},
                     %{"ref" => "b"}
                   ])
                 ]
               }
             )

    fail_job!(a)
    succeed_job!(b, head_sha: sha_b)

    child = Repo.get!(Job, c.id)
    assert child.status == "queued"
    assert child.admitted_repository["base"] == "dependency"

    {:ok, attempt} = Jobs.claim(child, "runner")

    assert {:ok, artifact} =
             Omashiki.Jobs.GitArtifact.provision_worktree(child, attempt, git_env: [])

    assert artifact.base_sha == sha_b
  end

  test "a cancelled parent cascade-cancels blocked children with cancel edge", %{token: token} do
    assert {:ok, [parent, child]} =
             Jobs.Admission.admit_batch(
               token,
               %{
                 "schema_version" => 1,
                 "correlation_id" => "parent-cancel",
                 "jobs" => [
                   batch_job("parent", []),
                   batch_job("child", [%{"ref" => "parent"}])
                 ]
               }
             )

    assert {:ok, %Job{status: "cancelled"}} = Jobs.cancel(parent)

    cancelled_child = Repo.get!(Job, child.id)
    assert cancelled_child.status == "cancelled"
    assert cancelled_child.terminal_error["code"] == "dependency_failed"
  end

  defp load_config!(root) do
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
            "pre_steps" => [],
            "post_steps" => [],
            "policy" => %{"mode" => "off"},
            "network" => "none",
            "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
          }
        }
      },
      path: Path.join(root, "omashiki.toml")
    )
  end

  defp diamond_batch do
    %{
      "schema_version" => 1,
      "correlation_id" => "diamond-batch",
      "jobs" => [
        batch_job("a", []),
        batch_job("b", []),
        batch_job("c", [%{"ref" => "a"}, %{"ref" => "b"}])
      ]
    }
  end

  defp batch_job(ref, depends_on) do
    %{
      "ref" => ref,
      "idempotency_key" => "dep-#{ref}-#{System.unique_integer([:positive])}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{
        "instruction" => "run",
        "context" => %{"ref" => ref},
        "branch" => "feat-batch-#{ref}"
      },
      "priority" => 0,
      "depends_on" => depends_on
    }
  end

  defp single_job(key, payload_extra, depends_on \\ []) do
    %{
      "schema_version" => 1,
      "idempotency_key" => key,
      "correlation_id" => "single-#{key}",
      "repo" => "app",
      "environment" => "safe",
      "payload" =>
        Map.merge(
          %{"instruction" => "run", "branch" => "feat-#{key}"},
          payload_extra
        ),
      "priority" => 0,
      "depends_on" => depends_on
    }
  end

  defp succeed_job!(job, opts \\ []) do
    {:ok, attempt} = Jobs.claim(job, "runner-#{job.id}")

    head_sha = Keyword.get(opts, :head_sha, String.duplicate("a", 40))

    assert {:ok, %JobAttempt{status: "succeeded"}} =
             Jobs.complete(attempt, attempt.lease_token, :succeeded, %{
               branch: "feat-#{job.id}",
               base_sha: String.duplicate("b", 40),
               head_sha: head_sha,
               worktree_clean: true,
               result: %{"summary" => "ok"}
             })
  end

  defp fail_job!(job) do
    {:ok, attempt} = Jobs.claim(job, "runner-#{job.id}")

    assert {:ok, %JobAttempt{status: "failed"}} =
             Jobs.complete(attempt, attempt.lease_token, :failed, %{
               error: error("worker_exit")
             })
  end

  defp commit_file!(repo_path, relative_path, contents) do
    path = Path.join(repo_path, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    {_, 0} = System.cmd("git", ["-C", repo_path, "add", relative_path])
    {_, 0} = System.cmd("git", ["-C", repo_path, "commit", "-m", "add #{relative_path}"])
    {sha, 0} = System.cmd("git", ["-C", repo_path, "rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp error(code), do: %{"code" => code, "message" => code, "details" => %{}}
end
