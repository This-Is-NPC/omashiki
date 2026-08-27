defmodule OmashikiWeb.JobLiveTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Omashiki.JobFixtures

  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Jobs.JobEvent
  alias Omashiki.Jobs.JobStep
  alias Omashiki.Repo
  alias Omashiki.UsageLedger.Entry

  test "renders job detail, attempts, steps, events, usage, and result", %{
    conn: conn,
    user: user,
    token: token
  } do
    {job, attempt} =
      job_fixture(user, token, %{
        status: "succeeded",
        payload: %{"branch" => "main", "checks" => ["test"]}
      })

    Repo.update!(JobAttempt.changeset(attempt, %{machine_id: "builder-07"}))

    Repo.insert!(
      JobStep.changeset(%JobStep{}, %{
        attempt_id: attempt.id,
        sequence: 1,
        key: "checkout",
        kind: "pre",
        status: "succeeded",
        started_at: DateTime.utc_now(:microsecond),
        finished_at: DateTime.utc_now(:microsecond)
      })
    )

    Repo.insert!(
      %JobEvent{}
      |> JobEvent.changeset(%{
        job_id: job.id,
        attempt: 1,
        sequence: 1,
        type: "job.succeeded",
        status: "succeeded",
        step: "succeeded",
        outcome: "succeeded",
        correlation_id: job.correlation_id,
        occurred_at: DateTime.utc_now(:microsecond),
        recorded_at: DateTime.utc_now(:microsecond),
        data: %{}
      })
    )

    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        request_id: "#{job.id}:1",
        job_id: job.id,
        attempt_id: attempt.id,
        turn: 1,
        source: "engine",
        input_tokens: 100,
        output_tokens: 25
      })
    )

    {:ok, _lv, html} = live(conn, ~p"/jobs/#{job.id}")

    assert html =~ "Job details"
    assert html =~ "Payload summary"
    assert html =~ "Attempts"
    assert html =~ "Steps"
    assert html =~ "Logs and events"
    assert html =~ "Usage"
    assert html =~ "Result or error"
    assert html =~ "Branch and SHAs"
    assert html =~ "checkout"
    assert html =~ "125"
    # Against the operator's own reading of the screen, not the raw document:
    # the CSRF and LiveView session tokens are base64url and will contain
    # short letter runs like these by chance.
    text = visible_text(html)
    # Which machine ran the attempt, read off the screen rather than the markup.
    assert text =~ "node builder-07"
    refute text =~ "Retry"
    refute text =~ "Audit"
    refute text =~ "Comments"
  end

  test "cancel action is authorized and updates the job", %{conn: conn, user: user, token: token} do
    {job, _attempt} = job_fixture(user, token, %{status: "queued"})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

    html = view |> element("button", "Cancel") |> render_click()
    assert html =~ "cancelled"
    assert html =~ "Job cancelled"
  end

  test "a job owned by another operator is not disclosed", %{conn: conn} do
    other = user_fixture()
    {other_token, _other_plaintext} = api_token_fixture(other)
    {job, _attempt} = job_fixture(other, other_token, %{})

    {:ok, _lv, html} = live(conn, ~p"/jobs/#{job.id}")
    assert html =~ "Job not found"
    refute html =~ job.id
  end

  test "realtime event refreshes the detail view", %{conn: conn, user: user, token: token} do
    {job, _attempt} = job_fixture(user, token, %{})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

    send(view.pid, {:job_event, %{status: "running"}})
    assert render(view) =~ "Job details"
  end
end
