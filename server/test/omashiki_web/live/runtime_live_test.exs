defmodule OmashikiWeb.RuntimeLiveTest do
  @moduledoc """
  A graph that cannot show a disagreement between its sources is not worth
  building, so these tests assert on the disagreements and on nothing else.

  Every assertion goes through `visible_text/1`. Matching raw markup would pass
  on class names and on the base64url session token, neither of which an
  operator can read.
  """

  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Omashiki.Runtime.Inspector

  setup %{user: user} do
    previous = Application.get_env(:omashiki, :runtime_census)
    on_exit(fn -> Application.put_env(:omashiki, :runtime_census, previous) end)

    {:ok, user: user}
  end

  # The pair the whole page exists for. Both are "an attempt and a container
  # that do not line up", and reading them as the same thing is how eighty-four
  # abandoned containers went unnoticed until they took down boot.
  test "an orphaned container and a process with no container read differently",
       %{conn: conn} do
    orphan = attempt_id()
    lonely = attempt_id()

    hold_registration(lonely)
    stage_census([container("aaaaaaaaaaaa", "job-#{orphan}")])

    {:ok, _lv, html} = live(conn, ~p"/runtime")
    text = visible_text(html)

    assert text =~ "Orphan container"
    assert text =~ "Process without container"

    # …and each is attached to the right thing, not merely both present.
    assert text =~ String.slice(orphan, 0, 8)
    assert text =~ String.slice(lonely, 0, 8)
    assert text =~ "aaaaaaaaaaaa"
  end

  test "a container owned by a live process reads as linked", %{conn: conn} do
    id = attempt_id()

    hold_registration(id)
    stage_census([container("bbbbbbbbbbbb", "job-#{id}")])

    {:ok, _lv, html} = live(conn, ~p"/runtime")
    text = visible_text(html)

    assert text =~ "Linked"
    refute text =~ "Orphan container"
    refute text =~ "Process without container"
  end

  test "a container with no scope label at all is still shown as an orphan", %{conn: conn} do
    stage_census([container("cccccccccccc", nil)])

    {:ok, _lv, html} = live(conn, ~p"/runtime")

    assert visible_text(html) =~ "Orphan container"
  end

  test "a quiet runtime says so rather than showing an empty table", %{conn: conn} do
    stage_census([])

    {:ok, _lv, html} = live(conn, ~p"/runtime")
    text = visible_text(html)

    assert text =~ "Nothing is running"
    refute text =~ "Orphan container"
  end

  # An unreachable daemon and a host with no containers produce the same empty
  # list. Reporting them the same way would tell an operator "all clear" in the
  # middle of an outage.
  test "an unreachable runtime is reported, not rendered as an idle host", %{conn: conn} do
    Application.put_env(
      :omashiki,
      :runtime_census,
      {__MODULE__, :unavailable_census, []}
    )

    Inspector.refresh()

    {:ok, _lv, html} = live(conn, ~p"/runtime")
    text = visible_text(html)

    assert text =~ "unreachable"
    refute text =~ "Nothing is running"
  end

  test "the runtime screen is on the primary navigation and requires an operator", %{conn: conn} do
    stage_census([])

    {:ok, _lv, html} = live(conn, ~p"/runtime")
    assert html =~ ~s(href="/runtime")

    anonymous = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/login"}}} = live(anonymous, ~p"/runtime")
  end

  @doc false
  def staged_census(entries), do: {:ok, entries}

  @doc false
  def unavailable_census, do: {:error, :docker_unavailable}

  defp stage_census(entries) do
    Application.put_env(:omashiki, :runtime_census, {__MODULE__, :staged_census, [entries]})
    Inspector.refresh()
    :ok
  end

  # A real entry in the registry the inspector reads, held by a real live
  # process. Standing up a `Runtime.Attempt` would run an actual job; what the
  # join cares about is that the attempt id is registered and its owner is
  # alive, which is exactly this.
  defp hold_registration(attempt_id) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} =
          Registry.register(Omashiki.Runtime.AttemptRegistry, {:attempt, attempt_id}, nil)

        send(test, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 1_000
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp container(id, scope_id) do
    %{
      id: id,
      scope_id: scope_id,
      state: "running",
      status: "Up 2 minutes",
      created_at: System.system_time(:second) - 120
    }
  end

  defp attempt_id, do: Ecto.UUID.generate()
end
