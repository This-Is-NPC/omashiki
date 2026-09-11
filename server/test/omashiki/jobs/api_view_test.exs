defmodule Omashiki.Jobs.ApiViewTest do
  use Omashiki.DataCase, async: true

  import Ecto.Query
  import Omashiki.Fixtures
  import Omashiki.JobFixtures

  alias Omashiki.Jobs.{Api, Job, JobStep}
  alias Omashiki.Repo

  setup do
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    %{user: user, token: token}
  end

  test "rows carry the current attempt and its steps in order", %{user: user, token: token} do
    {job, attempt} = job_fixture(user, token, %{status: "running"})
    insert_step(attempt, 2, "post", "pending")
    insert_step(attempt, 1, "agent", "running")

    assert [%{job: %Job{id: id}, attempt: %{id: attempt_id}, steps: steps}] =
             Api.list_for_view(user)

    assert id == job.id
    assert attempt_id == attempt.id
    assert Enum.map(steps, & &1.key) == ["agent", "post"]
  end

  test "filters combine", %{user: user, token: token} do
    {wanted, _} = job_fixture(user, token, %{status: "failed", priority: 3})
    job_fixture(user, token, %{status: "failed", priority: 1})
    job_fixture(user, token, %{status: "running", priority: 3})
    job_fixture(user, token, %{status: "failed", priority: 3, environment: "codex"})

    rows =
      Api.list_for_view(user,
        filter: %{status: ["failed"], priority: [3], environment: ["opencode"]}
      )

    assert Enum.map(rows, & &1.job.id) == [wanted.id]
  end

  test "since compares with submission time", %{user: user, token: token} do
    {recent, _} = job_fixture(user, token)
    {old, _} = job_fixture(user, token)
    now = DateTime.utc_now()

    Repo.update_all(from(j in Job, where: j.id == ^old.id),
      set: [inserted_at: DateTime.add(now, -3, :day)]
    )

    rows = Api.list_for_view(user, filter: %{since: DateTime.add(now, -1, :day)})
    assert Enum.map(rows, & &1.job.id) == [recent.id]
  end

  test "worker filter uses the current attempt", %{user: user, token: token} do
    {job, attempt} = job_fixture(user, token, %{status: "running"})
    attempt |> Ecto.Changeset.change(machine_id: "vps-1") |> Repo.update!()
    job_fixture(user, token, %{status: "running"})

    assert [%{job: %Job{id: id}}] = Api.list_for_view(user, filter: %{worker: ["vps-1"]})
    assert id == job.id
  end

  test "sort and limit apply in the query", %{user: user, token: token} do
    {low, _} = job_fixture(user, token, %{priority: 0})
    {high, _} = job_fixture(user, token, %{priority: 3})
    {middle, _} = job_fixture(user, token, %{priority: 2})

    assert Enum.map(Api.list_for_view(user, sort: {:priority, :desc}), & &1.job.id) ==
             [high.id, middle.id, low.id]

    assert Enum.map(Api.list_for_view(user, sort: {:priority, :asc}, limit: 1), & &1.job.id) ==
             [low.id]
  end

  test "only the operator's jobs are returned", %{user: user, token: token} do
    other = user_fixture()
    {other_token, _plaintext} = api_token_fixture(other)
    job_fixture(other, other_token)
    {mine, _} = job_fixture(user, token)

    assert Enum.map(Api.list_for_view(user), & &1.job.id) == [mine.id]
  end

  defp insert_step(attempt, sequence, key, status) do
    %JobStep{}
    |> JobStep.changeset(%{
      attempt_id: attempt.id,
      sequence: sequence,
      key: key,
      kind: key,
      status: status
    })
    |> Repo.insert!()
  end
end
