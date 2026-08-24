defmodule Omashiki.Integration.QueueLoadTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Admission, ExecutionCapacity, Job, JobEvent}
  alias Omashiki.Repo

  @tag :integration
  @job_count 1_000
  @capacity 8

  test "keeps 1000 durable jobs lossless while running at the eight-job ceiling" do
    root = Path.join(System.tmp_dir!(), "omashiki-load-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q", "-b", "main"])

    {_, 0} =
      System.cmd("git", ["-C", repo_path, "commit", "--allow-empty", "-q", "-m", "init"],
        env: git_identity()
      )

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "harnesses" => %{
          "opencode" => %{
            "adapter" => "opencode",
            "runtime" => "docker",
            "image" => "agent:latest"
          }
        },
        "environments" => %{
          "none" => %{
            "harness" => "opencode",
            "executables" => ["git"],
            "pre_steps" => [],
            "post_steps" => [],
            "timeout_ms" => 1_000,
            "caches" => [],
            "mounts" => [],
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

    jobs =
      1..@job_count
      |> Enum.map(&request/1)
      |> Enum.chunk_every(Admission.max_batch_size())
      |> Enum.flat_map(fn requests ->
        assert {:ok, admitted} = Admission.admit_batch(token, batch(requests))
        admitted
      end)

    assert length(jobs) == @job_count
    assert Repo.aggregate(from(j in Job, where: j.status == "queued"), :count, :id) == @job_count

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "Omashiki.Jobs.DispatchWorker"),
             :count,
             :id
           ) == @job_count

    jobs
    |> Enum.chunk_every(@capacity)
    |> Enum.each(fn batch_jobs ->
      claims =
        Enum.map(batch_jobs, fn job ->
          assert {:ok, attempt} = Jobs.claim(job, "load-runner-#{System.unique_integer()}")
          attempt
        end)

      assert length(claims) == @capacity
      assert Repo.get!(ExecutionCapacity, 1).active == @capacity

      assert Repo.aggregate(
               from(j in Job, where: j.status == "provisioning"),
               :count,
               :id
             ) == @capacity

      Enum.each(claims, fn attempt ->
        assert {:ok, %{status: "succeeded"}} =
                 Jobs.complete(attempt, attempt.lease_token, :succeeded, success_attrs())
      end)
    end)

    assert Repo.aggregate(from(j in Job, where: j.status == "succeeded"), :count, :id) ==
             @job_count

    assert Repo.aggregate(
             from(e in JobEvent, where: e.status == "succeeded"),
             :count,
             :event_id
           ) == @job_count

    terminal_counts =
      from(e in JobEvent,
        where: e.status in ["succeeded", "failed", "cancelled"],
        group_by: e.job_id,
        select: count(e.event_id)
      )
      |> Repo.all()

    assert length(terminal_counts) == @job_count
    assert Enum.all?(terminal_counts, &(&1 == 1))
    assert Repo.get!(ExecutionCapacity, 1).active == 0
  end

  defp batch(requests),
    do: %{"schema_version" => 1, "correlation_id" => "load", "jobs" => requests}

  defp request(number) do
    %{
      "ref" => "job-#{number}",
      "idempotency_key" => "load-#{number}",
      "repo" => "app",
      "environment" => "none",
      "payload" => %{"instruction" => "load #{number}", "context" => %{"number" => number}},
      "priority" => rem(number, 4)
    }
  end

  defp success_attrs do
    %{
      branch: "omashiki/load",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      worktree_clean: true,
      result: %{"load" => true}
    }
  end

  defp git_identity do
    [
      {"GIT_AUTHOR_NAME", "Queue load test"},
      {"GIT_AUTHOR_EMAIL", "queue-load@example.test"},
      {"GIT_COMMITTER_NAME", "Queue load test"},
      {"GIT_COMMITTER_EMAIL", "queue-load@example.test"}
    ]
  end
end
