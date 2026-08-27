defmodule Omashiki.Jobs.ParentCascadeTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "omashiki-parent-cascade-#{System.unique_integer([:positive])}"
      )

    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    load_config!(root)

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, token: token}
  end

  test "a failed parent cascade-cancels blocked children", %{token: token} do
    {:ok, [parent, child]} = Jobs.Admission.admit_batch(token, batch_request())
    assert parent.status == "queued"
    assert child.status == "blocked"

    {:ok, attempt} = Jobs.claim(parent, "parent-runner")

    assert {:ok, %JobAttempt{status: "failed"}} =
             Jobs.complete(attempt, attempt.lease_token, :failed, %{
               error: error("worker_exit")
             })

    assert Repo.get!(Job, parent.id).status == "failed"

    cancelled_child = Repo.get!(Job, child.id)
    assert cancelled_child.status == "cancelled"
    assert cancelled_child.finished_at
    assert cancelled_child.terminal_error["details"]["parent_job_id"] == parent.id
    assert cancelled_child.terminal_error["code"] == "parent_failed"

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^child.id and e.status == "cancelled"),
             :count,
             :event_id
           ) == 1
  end

  test "a cancelled parent cascade-cancels blocked children", %{token: token} do
    {:ok, [parent, child]} = Jobs.Admission.admit_batch(token, batch_request())
    {:ok, attempt} = Jobs.claim(parent, "parent-runner")

    assert {:ok, %Job{status: "cancelled"}} = Jobs.cancel(parent)
    assert Repo.get!(JobAttempt, attempt.id).status == "cancelled"

    cancelled_child = Repo.get!(Job, child.id)
    assert cancelled_child.status == "cancelled"
    assert cancelled_child.terminal_error["details"]["parent_job_id"] == parent.id
    assert cancelled_child.terminal_error["code"] == "parent_cancelled"
  end

  test "a queued parent cancelled without a claim cascade-cancels blocked children", %{
    token: token
  } do
    {:ok, [parent, child]} = Jobs.Admission.admit_batch(token, batch_request())

    assert {:ok, %Job{status: "cancelled"}} = Jobs.cancel(parent)

    cancelled_child = Repo.get!(Job, child.id)
    assert cancelled_child.status == "cancelled"
    assert cancelled_child.terminal_error["details"]["parent_job_id"] == parent.id
    assert cancelled_child.terminal_error["code"] == "parent_cancelled"
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

  defp batch_request do
    %{
      "schema_version" => 1,
      "correlation_id" => "parent-cascade-batch",
      "jobs" => [batch_job("parent"), batch_job("child", "parent")]
    }
  end

  defp batch_job(ref, parent_ref \\ nil) do
    job = %{
      "ref" => ref,
      "idempotency_key" => "cascade-#{ref}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{
        "instruction" => "run",
        "context" => %{"ref" => ref},
        "branch" => "feat-batch-#{ref}"
      },
      "priority" => 0
    }

    if parent_ref, do: Map.put(job, "parent_ref", parent_ref), else: job
  end

  defp error(code), do: %{"code" => code, "message" => code, "details" => %{}}
end
