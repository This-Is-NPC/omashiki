defmodule OmashikiWeb.QueueLiveTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Omashiki.JobFixtures

  test "renders blocked, queued, and running jobs with operational fields", %{
    conn: conn,
    user: user,
    token: token
  } do
    {parent, _attempt} = job_fixture(user, token, %{idempotency_key: "parent-ui"})
    {_queued, _attempt} = job_fixture(user, token, %{idempotency_key: "queued-ui", priority: 2})

    {_blocked, _attempt} =
      job_fixture(user, token, %{
        idempotency_key: "blocked-ui",
        status: "blocked",
        parent_job_id: parent.id
      })

    {_running, _attempt} =
      job_fixture(user, token, %{idempotency_key: "running-ui", status: "running"})

    {:ok, _lv, html} = live(conn, ~p"/queue")

    assert html =~ "Blocked"
    assert html =~ "Queued"
    assert html =~ "Running"
    assert html =~ "client"
    assert html =~ "repository"
    assert html =~ "environment"
    assert html =~ "attempt"
    refute html =~ "DAG"
    refute html =~ "drag"
  end

  test "refreshes when a durable job update is broadcast", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/queue")
    refute html =~ "job-update-marker"

    send(view.pid, {:job_event, %{status: "queued"}})
    assert render(view) =~ "Queued"
  end
end
