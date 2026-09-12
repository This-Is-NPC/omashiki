defmodule OmashikiWeb.Api.FleetControllerTest do
  use OmashikiWeb.ConnCase, async: false

  @moduletag :api

  import Omashiki.JobFixtures

  alias Omashiki.Worker.Presence

  setup do
    Presence.reset()
    on_exit(fn -> Presence.reset() end)
  end

  test "lists reported workers and names only the caller's jobs",
       %{conn: conn, user: user, token: token} do
    {job, attempt} = job_fixture(user, token, %{status: "running"})

    other = user_fixture()
    {other_token, _plaintext} = api_token_fixture(other)
    {_other_job, other_attempt} = job_fixture(other, other_token, %{status: "running"})

    :ok =
      Presence.report("worker-1", %{
        free_slots: 0,
        capacity: 2,
        containers: [
          container("aaaaaaaaaaaa", attempt.id),
          container("bbbbbbbbbbbb", other_attempt.id),
          container("cccccccccccc", nil)
        ]
      })

    body = conn |> get(~p"/api/v1/fleet") |> json_response(200)
    node = Enum.find(body["data"], &(&1["machine_id"] == "worker-1"))

    assert %{"kind" => "worker", "stale" => false, "capacity" => 2, "free_slots" => 0} = node

    jobs = Map.new(node["containers"], &{&1["id"], &1["job_id"]})
    assert jobs == %{"aaaaaaaaaaaa" => job.id, "bbbbbbbbbbbb" => nil, "cccccccccccc" => nil}
    refute Enum.any?(node["containers"], &Map.has_key?(&1, "attempt_id"))
  end

  @tag :unauthenticated
  test "requires an operator token", %{conn: conn} do
    assert conn |> get(~p"/api/v1/fleet") |> json_response(401)
  end

  defp container(id, attempt_id) do
    %{
      id: id,
      attempt_id: attempt_id,
      scope_id: attempt_id && "job-" <> attempt_id,
      state: "running",
      created_at: nil,
      started_at: nil
    }
  end
end
