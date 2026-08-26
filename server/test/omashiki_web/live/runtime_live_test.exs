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

  # A partially-applied configuration is a first-class state, so the screen has
  # to be able to say so — with a number, and with which containers are on
  # which side of it. All of this reads through `visible_text/1`: a percentage
  # rendered into a class name would be invisible to the operator.
  describe "configuration rollout" do
    setup do
      root = Path.join(System.tmp_dir!(), "omashiki-live-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      assert {_output, 0} =
               System.cmd("git", ["init", "--quiet", Path.join(root, "repo")],
                 stderr_to_stdout: true
               )

      previous = Application.get_env(:omashiki, :config_path)
      Application.put_env(:omashiki, :config_path, Path.join(root, "omashiki.toml"))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:omashiki, :config_path, previous),
          else: Application.delete_env(:omashiki, :config_path)

        System.delete_env("OMASHIKI_TEST_LIVE_KEY")
        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "an attempt admitted under a superseded config is shown as partially applied",
         %{conn: conn, user: user} do
      {token, _plaintext} = api_token_fixture(user)

      {_job, attempt} =
        Omashiki.JobFixtures.job_fixture(user, token, %{
          status: "running",
          registry_digest: String.duplicate("9", 64)
        })

      stage_census([container("dddddddddddd", "job-#{attempt.id}")])

      {:ok, _lv, html} = live(conn, ~p"/runtime")
      text = visible_text(html)

      # Not `=~ "0%"`: "100%" contains "0%", so that assertion passes on a
      # screen reporting the exact opposite of what this test is about.
      refute text =~ "100%"
      assert text =~ "prior config"
      assert text =~ "partially applied, 1 attempt(s) on prior config"
      assert text =~ "1 attempt(s) are finishing on the configuration they were admitted with"
      # The container itself is labelled, not just the fleet total.
      assert text =~ "dddddddddddd"
    end

    test "a fleet entirely on the live config reads as fully applied", %{conn: conn} do
      stage_census([])

      {:ok, _lv, html} = live(conn, ~p"/runtime")
      text = visible_text(html)

      assert text =~ "100%"
      assert text =~ "Every active attempt is running against the live configuration"
      refute text =~ "prior config"
    end

    test "the declared rollout mode is on the screen", %{conn: conn} do
      stage_census([])

      {:ok, _lv, html} = live(conn, ~p"/runtime")
      assert visible_text(html) =~ "gradual"
    end

    test "reloading applies a new generation without restarting the core", %{conn: conn} do
      stage_census([])
      {:ok, lv, _html} = live(conn, ~p"/runtime")

      generation = Omashiki.Config.generation()
      path = write_toml(model: "swapped-model")

      text =
        lv
        |> element("button", "Reload configuration")
        |> render_click()
        |> visible_text()

      assert text =~ "Applied generation"
      assert Omashiki.Config.generation() > generation
      assert {:ok, resolved} = Omashiki.Config.resolve_job("app", "opencode")
      assert [%{model: "swapped-model"}] = resolved.environment.credentials

      refute is_nil(path)
    end

    # A rejected file must not read as a successful apply, and the operator has
    # to be told which configuration is actually serving requests.
    test "a reload that fails on an unset ${env:VAR} says the previous config still serves",
         %{conn: conn} do
      System.put_env("OMASHIKI_TEST_LIVE_KEY", "set-for-now")
      write_toml(model: "good-model", api_key: "${env:OMASHIKI_TEST_LIVE_KEY}")
      assert {:ok, _info} = Omashiki.Config.reload(toml_path())
      generation = Omashiki.Config.generation()

      System.delete_env("OMASHIKI_TEST_LIVE_KEY")
      write_toml(model: "bad-model", api_key: "${env:OMASHIKI_TEST_LIVE_KEY}")

      stage_census([])
      {:ok, lv, _html} = live(conn, ~p"/runtime")

      text =
        lv
        |> element("button", "Reload configuration")
        |> render_click()
        |> visible_text()

      assert text =~ "Reload rejected, previous configuration still serving"
      assert text =~ "OMASHIKI_TEST_LIVE_KEY"
      assert Omashiki.Config.generation() == generation

      assert {:ok, resolved} = Omashiki.Config.resolve_job("app", "opencode")
      assert [%{model: "good-model", api_key: "set-for-now"}] = resolved.environment.credentials
    end
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

  defp toml_path, do: Application.fetch_env!(:omashiki, :config_path)

  defp write_toml(opts) do
    model = Keyword.fetch!(opts, :model)
    api_key = Keyword.get(opts, :api_key, "plaintext-key")
    path = toml_path()

    File.write!(path, """
    [limits]
    max_concurrent_containers = 4

    [repositories.app]
    path = "repo"
    base_branch = "main"

    [harnesses.opencode]
    adapter = "opencode"
    runtime = "docker"
    image = "omashiki/agent:latest"

    [credentials.provider]
    provider = "openai_compat"
    model = "#{model}"
    api_key = "#{api_key}"

    [environments.opencode]
    harness = "opencode"
    executables = ["git"]
    credentials = ["provider"]
    caches = []
    timeout_ms = 1800000
    network = "restricted"
    mounts = []
    pre_steps = []
    post_steps = []

    [environments.opencode.policy]
    mode = "off"

    [environments.opencode.resources]
    cpus = 2.0
    memory = "2GB"
    pids = 256
    """)

    path
  end
end
