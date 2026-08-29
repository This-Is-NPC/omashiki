defmodule Omashiki.Jobs.OrderingTest do
  use Omashiki.DataCase, async: false
  use Oban.Testing, repo: Omashiki.Repo

  import Ecto.Query

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-ordering-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "presets" => %{
          "opencode" => %{"plugin" => "opencode", "options" => %{}}
        },
        "runtimes" => %{
          "docker" => %{
            "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
          }
        },
        "environments" => %{
          "safe" => %{
            "runtime" => "docker.runc.debian",
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

  test "success queues direct children once in priority/FIFO order", %{token: token} do
    assert {:ok, [root, first, second, third]} =
             Jobs.Admission.admit_batch(
               token,
               batch_request([
                 {"root", [], 0},
                 {"first", [%{"ref" => "root"}], 1},
                 {"second", [%{"ref" => "root"}], 1},
                 {"third", [%{"ref" => "root"}], 0}
               ])
             )

    assert {:ok, _running} = Jobs.start(root)
    assert {:ok, _succeeded} = Jobs.succeed(root, success_attrs())
    assert {:ok, _same} = Jobs.succeed(root, success_attrs())

    children =
      Repo.all(
        from(d in Omashiki.Jobs.JobDependency,
          join: j in Job,
          on: j.id == d.job_id,
          where: d.depends_on_job_id == ^root.id,
          order_by: [asc: j.inserted_at, asc: j.id],
          select: j
        )
      )

    assert Enum.map(children, & &1.status) == ["queued", "queued", "queued"]
    assert Repo.aggregate(Oban.Job, :count, :id) == 4

    dispatches =
      Oban.Job
      |> where([j], j.worker == "Omashiki.Jobs.DispatchWorker")
      |> order_by([j], asc: j.priority, asc: j.inserted_at, asc: j.id)
      |> Repo.all()

    assert Enum.map(dispatches, & &1.priority) == [0, 0, 1, 1]

    assert Enum.map(Enum.drop(dispatches, 1), & &1.args["job_id"]) ==
             [third.id, first.id, second.id]

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^first.id and e.status == "queued"),
             :count,
             :event_id
           ) == 1

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^second.id and e.status == "queued"),
             :count,
             :event_id
           ) == 1

    assert Repo.aggregate(
             from(a in JobAttempt, where: a.job_id == ^first.id and a.status == "queued"),
             :count,
             :id
           ) == 1
  end

  test "failure and cancellation cascade-cancel blocked descendants", %{token: token} do
    assert {:ok, [root, child]} =
             Jobs.Admission.admit_batch(
               token,
               batch_request([{"root", [], 0}, {"child", [%{"ref" => "root"}], 0}])
             )

    assert {:ok, _cancelled} = Jobs.cancel(root)

    assert Repo.get!(Job, child.id).status == "cancelled"

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^child.id and e.status == "cancelled"),
             :count,
             :event_id
           ) == 1

    assert Repo.aggregate(Oban.Job, :count, :id) == 1

    assert {:ok, [failed_root, failed_child]} =
             Jobs.Admission.admit_batch(
               token,
               batch_request([
                 {"failed-root", [], 0},
                 {"failed-child", [%{"ref" => "failed-root"}], 0}
               ])
             )

    assert {:ok, _running} = Jobs.start(failed_root)
    assert {:ok, _failed} = Jobs.fail(failed_root, error_attrs("failed"))
    assert Repo.get!(Job, failed_child.id).status == "cancelled"

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^failed_child.id and e.status == "cancelled"),
             :count,
             :event_id
           ) == 1
  end

  test "retry success does not re-queue cascade-cancelled children", %{token: token} do
    assert {:ok, [root, child]} =
             Jobs.Admission.admit_batch(
               token,
               batch_request([{"root", [], 0}, {"child", [%{"ref" => "root"}], 0}])
             )

    assert {:ok, _running} = Jobs.start(root)
    assert {:ok, _failed} = Jobs.fail(root, error_attrs("failed"))
    {:ok, retried} = Jobs.retry(root)
    assert retried.current_attempt == 2
    assert {:ok, _running} = Jobs.start(retried)
    assert {:ok, _succeeded} = Jobs.succeed(retried, success_attrs())
    assert {:ok, _same} = Jobs.succeed(retried, success_attrs())

    assert Repo.get!(Job, child.id).status == "cancelled"

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^child.id and e.status == "queued"),
             :count,
             :event_id
           ) == 0

    assert Repo.aggregate(Oban.Job, :count, :id) == 1
  end

  test "concurrent parent success has one unlock and one child dispatch", %{token: token} do
    assert {:ok, [root, child]} =
             Jobs.Admission.admit_batch(
               token,
               batch_request([{"root", [], 0}, {"child", [%{"ref" => "root"}], 0}])
             )

    assert {:ok, _running} = Jobs.start(root)

    results =
      Task.async_stream(1..2, fn _ -> Jobs.succeed(root, success_attrs()) end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Job{status: "succeeded"}}, &1))

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^child.id and e.status == "queued"),
             :count,
             :event_id
           ) == 1

    assert Repo.aggregate(Oban.Job, :count, :id) == 2
  end

  test "dispatch intent survives an Oban process restart", %{token: token} do
    assert {:ok, job} = Jobs.Admission.admit(token, single_request())
    dispatch = Repo.one!(from(j in Oban.Job, where: j.worker == "Omashiki.Jobs.DispatchWorker"))

    assert :ok = Supervisor.terminate_child(Omashiki.Supervisor, Oban)
    assert {:ok, _pid} = Supervisor.restart_child(Omashiki.Supervisor, Oban)
    assert Repo.get!(Job, job.id).status == "queued"
    assert Repo.get!(Oban.Job, dispatch.id).id == dispatch.id
  end

  defp batch_request(jobs) do
    %{
      "schema_version" => 1,
      "correlation_id" => "batch-#{System.unique_integer([:positive])}",
      "jobs" =>
        Enum.map(jobs, fn {ref, depends_on, priority} ->
          job = %{
            "ref" => ref,
            "idempotency_key" => "#{ref}-#{System.unique_integer([:positive])}",
            "repo" => "app",
            "environment" => "safe",
            "payload" => %{
              "instruction" => "run",
              "context" => %{"ref" => ref},
              "branch" => "feat-batch-#{ref}"
            },
            "priority" => priority
          }

          Map.put(job, "depends_on", depends_on)
        end)
    }
  end

  defp single_request do
    %{
      "schema_version" => 1,
      "idempotency_key" => "restart-#{System.unique_integer([:positive])}",
      "correlation_id" => "restart-correlation",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{"instruction" => "run", "branch" => "feat-test"},
      "priority" => 0
    }
  end

  defp success_attrs do
    %{
      branch: "jobs/branch",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      worktree_clean: true,
      result: %{"ok" => true}
    }
  end

  defp error_attrs(code), do: %{error: %{"code" => code, "message" => code, "details" => %{}}}
end
