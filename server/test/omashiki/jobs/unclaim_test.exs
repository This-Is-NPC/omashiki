defmodule Omashiki.Jobs.UnclaimTest do
  use Omashiki.DataCase, async: false

  import Omashiki.JobFixtures

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{ExecutionCapacity, Job, JobAttempt}
  alias Omashiki.Repo

  setup do
    assert {:ok, _} = Jobs.sync_capacity()
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    {:ok, user: user, token: token}
  end

  defp queued_job!(user, token, attrs \\ %{}) do
    {job, _attempt} = job_fixture(user, token, Map.merge(%{status: "queued"}, attrs))
    job
  end

  test "releases provisioning claim back to queue", %{user: user, token: token} do
    job = queued_job!(user, token)
    machine = Config.current_machine().name

    assert {:ok, %JobAttempt{id: attempt_id, job_id: job_id, lease_token: lease}} =
             Jobs.claim_next("worker:box-a")

    assert job_id == job.id
    assert %ExecutionCapacity{active: 1} = Repo.get!(ExecutionCapacity, machine)

    assert {:ok, %Job{status: "queued", started_at: nil}} = Jobs.unclaim(attempt_id, lease)

    attempt = Repo.get!(JobAttempt, attempt_id)
    assert attempt.status == "queued"
    assert attempt.runner_id == nil
    assert attempt.lease_token == nil
    assert attempt.capacity_reserved == false

    assert %ExecutionCapacity{active: 0} = Repo.get!(ExecutionCapacity, machine)

    assert {:ok, %JobAttempt{id: reclaimed_id, job_id: ^job_id}} =
             Jobs.claim_next("worker:box-b")

    assert reclaimed_id == attempt_id
  end

  test "wrong lease returns stale_lease and leaves attempt provisioning", %{
    user: user,
    token: token
  } do
    _job = queued_job!(user, token)

    assert {:ok, %JobAttempt{id: attempt_id} = attempt} = Jobs.claim_next("worker:box-a")

    assert {:error, :stale_lease} = Jobs.unclaim(attempt, "not-the-lease")

    reloaded = Repo.get!(JobAttempt, attempt_id)
    assert reloaded.status == "provisioning"
    assert reloaded.lease_token == attempt.lease_token
  end

  test "unclaim errors after terminal completion", %{user: user, token: token} do
    _job = queued_job!(user, token)

    assert {:ok, %JobAttempt{} = attempt} = Jobs.claim_next("worker:box-a")

    assert {:ok, _} =
             Jobs.complete(attempt, attempt.lease_token, "succeeded", %{
               result: %{"ok" => true},
               branch: "omashiki/test",
               base_sha: String.duplicate("a", 40),
               head_sha: String.duplicate("b", 40),
               worktree_clean: true
             })

    assert {:error, :attempt_not_active} = Jobs.unclaim(attempt.id, attempt.lease_token)
  end
end
