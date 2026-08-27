defmodule OmashikiWeb.ConfigLiveTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders repository, environment, runtime, and host declarations", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/config")

    assert html =~ "Runtime configuration"
    assert html =~ "Host limits"
    assert html =~ "Repositories"
    assert html =~ "Environments"
    assert html =~ "Reload configuration"

    text = visible_text(html)
    refute text =~ "Save"
    refute text =~ "Edit"
    refute text =~ "Persona"
    refute text =~ "restart to change"
  end

  test "primary nav is only Home and Config", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/config")

    nav =
      html
      |> Floki.parse_document!()
      |> Floki.find("nav[aria-label=\"Primary\"]")

    assert Floki.attribute(nav, "a", "href") == ["/", "/config"]
  end

  test "cache purge action is available only for configured groups", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/config")
    html = render_click(view, "purge_cache", %{"group" => "not-configured"})
    assert html =~ "requires a configured group"
  end

  describe "configuration reload" do
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

    test "reloading applies a new generation without restarting the core", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/config")

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

    test "a reload that fails on an unset ${env:VAR} says the previous config still serves",
         %{conn: conn} do
      System.put_env("OMASHIKI_TEST_LIVE_KEY", "set-for-now")
      write_toml(model: "good-model", api_key: "${env:OMASHIKI_TEST_LIVE_KEY}")
      assert {:ok, _info} = Omashiki.Config.reload(toml_path())
      generation = Omashiki.Config.generation()

      System.delete_env("OMASHIKI_TEST_LIVE_KEY")
      write_toml(model: "bad-model", api_key: "${env:OMASHIKI_TEST_LIVE_KEY}")

      {:ok, lv, _html} = live(conn, ~p"/config")

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

    [presets.opencode]
    plugin = "opencode"

    [credentials.provider]
    provider = "openai_compat"
    model = "#{model}"
    api_key = "#{api_key}"

    [environments.opencode]
    isolation = "docker"
    image = "omashiki/agent:latest"
    sink = "git"
    packages = []
    preset = "opencode"
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
