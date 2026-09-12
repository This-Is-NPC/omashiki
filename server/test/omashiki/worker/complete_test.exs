defmodule Omashiki.Worker.CompleteTest do
  use Omashiki.DataCase, async: true

  import Omashiki.JobFixtures

  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Repo
  alias Omashiki.Worker.Complete

  describe "to_map/1 and from_map/1" do
    test "round-trips and Jason-encodes git" do
      complete = %Complete{
        kind: :git,
        remote: "origin",
        branch: "omashiki/test",
        base_sha: String.duplicate("a", 40),
        head_sha: String.duplicate("b", 40)
      }

      map = Complete.to_map(complete)
      assert Jason.encode!(map)
      assert {:ok, round} = Complete.from_map(map)
      assert Complete.to_map(round) == map
    end

    test "round-trips git completion metadata" do
      complete = %Complete{
        kind: :git,
        remote: "origin",
        branch: "omashiki/test",
        base_sha: String.duplicate("a", 40),
        head_sha: String.duplicate("b", 40),
        summary: "added hello.py",
        changes: %{
          "files_changed" => 1,
          "insertions" => 3,
          "deletions" => 0,
          "files" => [%{"path" => "hello.py", "insertions" => 3, "deletions" => 0}]
        },
        compare_url: "https://github.com/acme/repo/compare/a...b"
      }

      map = Complete.to_map(complete)
      assert {:ok, round} = Complete.from_map(map)
      assert round.summary == "added hello.py"

      assert round.changes["files"] == [
               %{"path" => "hello.py", "insertions" => 3, "deletions" => 0}
             ]

      assert round.compare_url == complete.compare_url
    end

    test "round-trips and Jason-encodes files" do
      complete = %Complete{
        kind: :files,
        changed_bytes: 128,
        blob_digest: String.duplicate("c", 64),
        blob_path: "/tmp/blob.tar"
      }

      map = Complete.to_map(complete)
      assert Jason.encode!(map)
      assert {:ok, round} = Complete.from_map(map)
      assert Complete.to_map(round) == map
    end

    test "round-trips and Jason-encodes none" do
      complete = %Complete{kind: :none, changed_bytes: 0}

      map = Complete.to_map(complete)
      assert Jason.encode!(map)
      assert {:ok, round} = Complete.from_map(map)
      assert Complete.to_map(round) == map
    end

    test "round-trips and Jason-encodes error" do
      complete = %Complete{
        kind: :error,
        code: "dispatch_failed",
        message: "runner unavailable",
        details: %{"reason" => "timeout"}
      }

      map = Complete.to_map(complete)
      assert Jason.encode!(map)
      assert {:ok, round} = Complete.from_map(map)
      assert Complete.to_map(round) == map
    end
  end

  describe "from_job/1" do
    setup do
      user = user_fixture()
      {token, _plaintext} = api_token_fixture(user)
      {:ok, user: user, token: token}
    end

    test "builds git complete from a succeeded git job", %{user: user, token: token} do
      {job, _attempt} =
        job_fixture(user, token, %{
          status: "succeeded",
          admitted_environment: %{"name" => "opencode", "sink" => "git"}
        })

      complete = Complete.from_job(job)

      assert complete.kind == :git
      assert complete.branch == "feat-fixture-run-001"
      assert complete.base_sha == String.duplicate("1", 40)
      assert complete.head_sha == String.duplicate("2", 40)
    end

    test "builds files complete from a succeeded files job", %{user: user, token: token} do
      digest = String.duplicate("f", 64)

      {job, attempt} =
        job_fixture(user, token, %{
          status: "succeeded",
          repository: nil,
          admitted_repository: nil,
          admitted_repository_digest: nil,
          admitted_environment: %{"name" => "files-env", "sink" => "files"},
          terminal_result: %{
            "job_id" => "pending",
            "changed_bytes" => 256,
            "blob_digest" => digest,
            "sink" => "files"
          }
        })

      job =
        job
        |> Ecto.Changeset.change(%{
          terminal_result: %{
            "job_id" => to_string(job.id),
            "changed_bytes" => 256,
            "blob_digest" => digest,
            "sink" => "files"
          }
        })
        |> Repo.update!()

      attempt
      |> JobAttempt.changeset(%{
        branch: nil,
        base_sha: nil,
        head_sha: nil,
        worktree_clean: nil
      })
      |> Repo.update!()

      complete = Complete.from_job(job)

      assert complete.kind == :files
      assert complete.changed_bytes == 256
      assert complete.blob_digest == digest
      assert is_nil(complete.blob_path)
    end

    test "builds none complete from a succeeded none job", %{user: user, token: token} do
      {job, attempt} =
        job_fixture(user, token, %{
          status: "succeeded",
          repository: nil,
          admitted_repository: nil,
          admitted_repository_digest: nil,
          admitted_environment: %{"name" => "none-env", "sink" => "none"},
          terminal_result: %{"changed_bytes" => 12, "sink" => "none"}
        })

      attempt
      |> JobAttempt.changeset(%{
        branch: nil,
        base_sha: nil,
        head_sha: nil,
        worktree_clean: nil
      })
      |> Repo.update!()

      complete = Complete.from_job(job)

      assert complete.kind == :none
      assert complete.changed_bytes == 12
    end

    test "builds error complete from a failed job", %{user: user, token: token} do
      {job, _attempt} =
        job_fixture(user, token, %{
          status: "failed",
          terminal_error: %{"code" => "runner_failed", "message" => "boom"}
        })

      complete = Complete.from_job(job)

      assert complete.kind == :error
      assert complete.code == "runner_failed"
      assert complete.message == "boom"
    end
  end
end
