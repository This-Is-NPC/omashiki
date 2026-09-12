defmodule Omashiki.Jobs.ClaimNextTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query
  import Omashiki.JobFixtures

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

  test "returns the oldest queued job first", %{user: user, token: token} do
    older = queued_job!(user, token)
    newer = queued_job!(user, token)

    base = ~U[2026-01-01 00:00:00.000000Z]
    Repo.update_all(from(j in Job, where: j.id == ^older.id), set: [inserted_at: base])

    Repo.update_all(from(j in Job, where: j.id == ^newer.id),
      set: [inserted_at: DateTime.add(base, 60, :second)]
    )

    assert {:ok, %JobAttempt{job_id: first_id}} = Jobs.claim_next("worker:box-a")
    assert first_id == older.id

    assert {:ok, %JobAttempt{job_id: second_id}} = Jobs.claim_next("worker:box-a")
    assert second_id == newer.id

    assert {:ok, :empty} = Jobs.claim_next("worker:box-a")
  end

  test "skips when free_slots is zero" do
    assert {:ok, :empty} = Jobs.claim_next("worker:box-a", free_slots: 0)
  end

  test "returns capacity_exhausted when slots are full", %{user: user, token: token} do
    _job = queued_job!(user, token)
    Repo.update_all(from(c in ExecutionCapacity, update: [set: [active: c.capacity]]), [])

    assert {:error, :capacity_exhausted} = Jobs.claim_next("worker:box-a")
  end
end
