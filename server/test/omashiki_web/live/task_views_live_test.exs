defmodule OmashikiWeb.TaskViewsLiveTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Omashiki.JobFixtures

  alias Omashiki.Jobs.{Job, JobStep}
  alias Omashiki.Repo

  setup do
    dir =
      Path.join(System.tmp_dir!(), "omashiki-views-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    previous = Application.get_env(:omashiki, :ui_config_path)
    path = Path.join(dir, "ui.toml")
    Application.put_env(:omashiki, :ui_config_path, path)

    on_exit(fn ->
      Application.put_env(:omashiki, :ui_config_path, previous)
      File.rm_rf!(dir)
    end)

    {:ok, ui_path: path}
  end

  test "without a views file the built-in views render", %{conn: conn, user: user, token: token} do
    insert_job(user, token, "running", "bump-deps")

    {:ok, _lv, html} = live(conn, ~p"/")
    text = visible_text(html)

    assert text =~ "Built-in views"
    assert text =~ "Active"
    assert text =~ "Board"
    assert text =~ "Finished"
    assert text =~ "bump-deps"
  end

  test "home opens on the board and uses the full width", %{conn: conn} do
    {:ok, _lv, home} = live(conn, ~p"/")
    {:ok, _lv, system} = live(conn, ~p"/system")

    assert home |> Floki.parse_document!() |> Floki.find("h1") |> Floki.text() =~ "Board"
    refute home =~ "max-w-7xl"
    assert home =~ ~s(phx-hook="BoardHeight")
    assert system =~ "max-w-7xl"
  end

  test "a job event reloads the tasks without waiting for a timer",
       %{conn: conn, user: user, token: token} do
    {:ok, lv, html} = live(conn, ~p"/")
    refute html =~ "arrived-now"

    {job, _attempt} = insert_job(user, token, "queued", "arrived-now")
    send(lv.pid, {:job_updated, job.id})
    Process.sleep(400)

    assert render(lv) =~ "arrived-now"
  end

  # The clock moves relative times only; job rows change through events.
  test "the clock does not read jobs", %{conn: conn, user: user, token: token} do
    {:ok, lv, _html} = live(conn, ~p"/")

    insert_job(user, token, "queued", "no-event-yet")
    send(lv.pid, :clock)

    refute render(lv) =~ "no-event-yet"
  end

  test "the header shows the connection state instead of a refresh interval", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    text = visible_text(html)

    assert text =~ "live"
    assert text =~ "connecting…"
    assert html =~ "phx-connected:inline-flex"
    refute text =~ "updates every"
  end

  test "the fleet graph draws workers and containers and follows fleet events",
       %{conn: conn, user: user, token: token, ui_path: path} do
    Omashiki.Worker.Presence.reset()
    on_exit(fn -> Omashiki.Worker.Presence.reset() end)

    File.write!(path, """
    [[views]]
    name = "fleet"
    layout = "graph"
    fields = ["title", "environment"]
    """)

    {_job, attempt} = insert_job(user, token, "running", "graph-task")

    container = %{
      id: "aaaaaaaaaaaa",
      attempt_id: attempt.id,
      scope_id: "job-" <> attempt.id,
      state: "running",
      created_at: nil,
      started_at: DateTime.utc_now()
    }

    :ok =
      Omashiki.Worker.Presence.report("vps-graph", %{
        free_slots: 1,
        capacity: 2,
        containers: [container]
      })

    {:ok, lv, html} = live(conn, ~p"/")

    assert has_element?(lv, "#node-vps-graph")
    assert has_element?(lv, "#container-aaaaaaaaaaaa", "graph-task")
    assert visible_text(html) =~ "1 / 2"

    :ok =
      Omashiki.Worker.Presence.report("vps-graph", %{free_slots: 2, capacity: 2, containers: []})

    Process.sleep(400)

    refute has_element?(lv, "#container-aaaaaaaaaaaa")
    assert has_element?(lv, "#node-vps-graph")
  end

  test "a file view chooses the fields and filters the tasks",
       %{conn: conn, user: user, token: token, ui_path: path} do
    File.write!(path, """
    [[views]]
    name = "failures"
    title = "Failures"
    filter = { status = ["failed"] }
    fields = ["title", "error", "context.issue_url"]
    """)

    insert_job(user, token, "failed", "fix-login", %{"issue_url" => "https://tracker.test/1"})
    insert_job(user, token, "running", "bump-deps")

    {:ok, _lv, html} = live(conn, ~p"/")
    text = visible_text(html)

    assert text =~ "Views from #{path}"
    assert text =~ "Failures"
    assert text =~ "fix-login"
    assert text =~ "https://tracker.test/1"
    assert text =~ "issue_url"
    refute text =~ "bump-deps"

    headers = html |> Floki.parse_document!() |> Floki.find("thead th") |> Enum.map(&Floki.text/1)
    assert Enum.map(headers, &String.trim/1) == ["title", "error", "issue_url"]
  end

  test "each view in the file is a tab selected through the URL",
       %{conn: conn, ui_path: path} do
    File.write!(path, """
    [[views]]
    name = "first"
    title = "First view"

    [[views]]
    name = "second"
    title = "Second view"
    layout = "board"
    """)

    {:ok, _lv, html} = live(conn, ~p"/?view=second")

    tabs = html |> Floki.parse_document!() |> Floki.find("nav[aria-label=\"Views\"] a")
    assert Floki.attribute(tabs, "href") == ["/?view=first", "/?view=second"]
    assert html |> Floki.parse_document!() |> Floki.find("h1") |> Floki.text() =~ "Second view"
  end

  test "an undeclared view falls back to the default view with a notice", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/?view=missing")
    text = visible_text(html)

    assert text =~ ~s(View "missing" is not declared)
    assert text =~ "Active"
  end

  test "a board groups tasks by status in lifecycle order",
       %{conn: conn, user: user, token: token, ui_path: path} do
    File.write!(path, ~s([[views]]\nname = "board"\nlayout = "board"\n))
    insert_job(user, token, "queued", "waiting-task")
    insert_job(user, token, "running", "busy-task")

    {:ok, _lv, html} = live(conn, ~p"/")
    document = Floki.parse_document!(html)

    assert Floki.attribute(document, "section[aria-label]", "aria-label") ==
             ~w(blocked queued provisioning running succeeded failed cancelled)

    assert document |> Floki.find("section[aria-label=\"queued\"]") |> Floki.text() =~
             "waiting-task"

    assert document |> Floki.find("section[aria-label=\"running\"]") |> Floki.text() =~
             "busy-task"
  end

  test "summary blocks render when a view lists them", %{conn: conn, ui_path: path} do
    File.write!(path, ~s([[views]]\nname = "a"\nblocks = ["status_counts", "slots", "workers"]\n))

    {:ok, _lv, html} = live(conn, ~p"/")
    text = visible_text(html)

    assert text =~ "Status"
    assert text =~ "Slots"
    assert text =~ "Workers"
  end

  test "a changed file applies without a page reload", %{conn: conn, ui_path: path} do
    File.write!(path, ~s([[views]]\nname = "a"\ntitle = "Before"\n))
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Before"

    File.write!(path, ~s([[views]]\nname = "a"\ntitle = "After"\n))
    send(lv.pid, :clock)

    assert render(lv) =~ "After"
  end

  test "a rejected file keeps the last valid views and shows why", %{conn: conn, ui_path: path} do
    File.write!(path, ~s([[views]]\nname = "a"\ntitle = "Still here"\n))
    {:ok, lv, _html} = live(conn, ~p"/")

    File.write!(path, ~s([[views]]\nname = "a"\nfields = ["tokens"]\n))
    send(lv.pid, :clock)
    text = lv |> render() |> visible_text()

    assert text =~ "Views file rejected"
    assert text =~ ~s(unknown field "tokens")
    assert text =~ "Still here"
  end

  test "task details open from the list and show the current attempt",
       %{conn: conn, user: user, token: token} do
    {job, attempt} = insert_job(user, token, "running", "fix-login")
    attempt |> Ecto.Changeset.change(machine_id: "vps-1") |> Repo.update!()

    %JobStep{}
    |> JobStep.changeset(%{
      attempt_id: attempt.id,
      sequence: 1,
      key: "agent",
      kind: "agent",
      status: "running",
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> element("#task-#{job.id} a") |> render_click()
    assert_patch(lv, "/?view=board&job=#{job.id}")

    text = lv |> render() |> visible_text()
    assert has_element?(lv, "#task-detail")
    assert text =~ "Instruction for fix-login"
    assert text =~ "vps-1"
    assert text =~ "agent"
  end

  test "a task of another operator is not visible", %{conn: conn} do
    other = user_fixture()
    {other_token, _plaintext} = api_token_fixture(other)
    {job, _attempt} = insert_job(other, other_token, "running", "someone-else")

    {:ok, _lv, html} = live(conn, ~p"/?job=#{job.id}")
    text = visible_text(html)

    refute text =~ "someone-else"
    assert text =~ "Task not found"
  end

  # The guarantee behind the screen: it reads, it never writes. There is no
  # event handler at all, and opening, refreshing, and inspecting leave the
  # job exactly as it was.
  test "the screen cannot change a job", %{conn: conn, user: user, token: token} do
    {job, _attempt} = insert_job(user, token, "queued", "untouched")
    before = Repo.get!(Job, job.id)

    refute function_exported?(OmashikiWeb.TaskViewsLive, :handle_event, 3)

    {:ok, lv, html} = live(conn, ~p"/?job=#{job.id}")
    send(lv.pid, :clock)
    send(lv.pid, {:job_updated, job.id})
    text = lv |> render() |> visible_text()

    refute html =~ "phx-submit"
    refute text =~ "Cancel"
    refute text =~ "Retry"
    assert Repo.get!(Job, job.id) == before
  end

  defp insert_job(user, token, status, title, context \\ nil) do
    payload =
      %{"instruction" => "Instruction for #{title}", "title" => title}
      |> then(&if(context, do: Map.put(&1, "context", context), else: &1))

    job_fixture(user, token, %{status: status, payload: payload})
  end
end
