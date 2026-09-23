defmodule OmashikiWeb.ConfigFilesLiveTest do
  @moduledoc """
  The screen never writes a file the house loads without showing what changes
  and asking first, and never overwrites a file that changed since it was
  opened.
  """

  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Omashiki.Config
  alias Omashiki.ConfigFiles

  @views """
  [[views]]
  name = "mine"
  title = "Mine"
  """

  setup do
    Config.reset!()

    root =
      Path.join(System.tmp_dir!(), "omashiki-files-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    copy_plugins!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", Path.join(root, "repo")])

    path = Path.join(root, "omashiki.toml")
    File.write!(path, house_toml())
    previous = Map.new([:config_path, :ui_config_path], &{&1, Application.get_env(:omashiki, &1)})
    Application.put_env(:omashiki, :config_path, path)
    Application.put_env(:omashiki, :ui_config_path, Path.join(root, "ui.toml"))
    assert :ok = Config.load!(path)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:omashiki, key)
        {key, value} -> Application.put_env(:omashiki, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, path: path}
  end

  test "the Config screen links here", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/config")
    assert has_element?(view, ~s(a[href="/config/files"]), "Edit files")
  end

  describe "the list" do
    test "opens the applied document and groups include pieces under it", ctx do
      piece = Path.join(ctx.root, "pieces/credentials.toml")
      File.mkdir_p!(Path.dirname(piece))
      File.write!(piece, credential_toml("piece-model"))
      File.write!(ctx.path, ~s(include = ["pieces"]\n) <> house_toml(credentials: false))

      {:ok, view, _html} = live(ctx.conn, ~p"/config/files")

      assert has_element?(view, "#document-omashiki[aria-current=page]", "applied")
      assert has_element?(view, "#document-omashiki + ul #document-pieces\\/credentials\\.toml")
      assert has_element?(view, "#toml-editor[data-content*=pieces]")
      refute has_element?(view, "button", "Apply")
      refute has_element?(view, "button", "Delete")

      view |> element("#document-pieces\\/credentials\\.toml") |> render_click()
      assert has_element?(view, "h2", "include piece")
      assert has_element?(view, "#toml-editor[data-content*=piece-model]")
      refute has_element?(view, "button", "Delete")
    end

    test "switches to task views, which start empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config/files")
      view |> element("nav a", "Task views") |> render_click()

      assert has_element?(view, "p", "No task views file yet")
      refute has_element?(view, "#toml-editor")
    end

    test "reports an edit made outside Omashiki", ctx do
      ConfigFiles.list(:config)
      File.write!(ctx.path, house_toml(model: "outside"))

      {:ok, view, _html} = live(ctx.conn, ~p"/config/files")

      assert has_element?(view, "div", "Edited outside Omashiki")
      assert has_element?(view, "#toml-editor[data-content*=outside]")
    end
  end

  describe "new documents" do
    test "validate the name, then open the copy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config/files")
      view |> element("button", "New") |> render_click()

      view |> form("#new-document", %{"name" => "Not OK", "from" => "copy"}) |> render_submit()
      assert has_element?(view, "#new-document p", "lowercase letters")

      view |> form("#new-document", %{"name" => "omashiki", "from" => "copy"}) |> render_submit()
      assert has_element?(view, "#new-document p", "already exists")

      view |> form("#new-document", %{"name" => "next", "from" => "copy"}) |> render_submit()
      assert_patch(view, ~p"/config/files?kind=config&name=next")
      assert has_element?(view, "#document-next[aria-current=page]")
      assert {:ok, %{content: content}} = ConfigFiles.read(:config, "next")
      assert content == house_toml()
    end

    test "start blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config/files?kind=views")
      view |> element("button", "New") |> render_click()
      view |> form("#new-document", %{"name" => "mine"}) |> render_submit()

      assert_patch(view, ~p"/config/files?kind=views&name=mine")
      assert {:ok, %{content: ""}} = ConfigFiles.read(:views, "mine")
    end
  end

  test "deletes a draft after confirmation", %{conn: conn, user: user} do
    {:ok, _doc} = ConfigFiles.create(:config, "next", from: :blank, author: user)
    {:ok, view, _html} = live(conn, ~p"/config/files?kind=config&name=next")

    view |> element("button", "Delete") |> render_click()
    assert has_element?(view, "#confirm", "The draft and its history are removed")
    view |> element("#confirm button", "Cancel") |> render_click()
    refute has_element?(view, "#confirm")
    assert {:ok, _doc} = ConfigFiles.read(:config, "next")

    view |> element("button", "Delete") |> render_click()
    view |> element("#confirm button", "Delete") |> render_click()
    assert_patch(view, ~p"/config/files?kind=config")
    assert {:error, :not_found} = ConfigFiles.read(:config, "next")
  end

  test "check points the editor at the line of a decode error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/config/files")

    render_hook(view, "editor_changed", %{"content" => "a = 1\nnot [ toml\n"})
    assert has_element?(view, "p", "unsaved changes")
    view |> element("button", "Check") |> render_click()

    assert has_element?(view, "div", "Rejected")
    assert has_element?(view, "pre", "on line 2")
    assert_push_event(view, "editor_diagnostics", %{items: [%{line: 2, message: message}]})
    assert message =~ "expected '='"

    render_hook(view, "editor_changed", %{"content" => house_toml(model: "checked")})
    view |> element("button", "Check") |> render_click()

    assert has_element?(view, "div", "The file is valid.")
    assert has_element?(view, "#change-summary", "changed provider")
    assert_push_event(view, "editor_diagnostics", %{items: []})
  end

  test "saves a draft without asking, even when invalid", ctx do
    {:ok, _doc} = ConfigFiles.create(:config, "next", from: "omashiki", author: ctx.user)
    {:ok, view, _html} = live(ctx.conn, ~p"/config/files?kind=config&name=next")

    render_hook(view, "editor_save", %{"content" => "not [ toml"})

    refute has_element?(view, "#confirm")
    assert render(view) =~ "Saved next."
    refute has_element?(view, "p", "unsaved changes")
    assert {:ok, %{content: "not [ toml"}} = ConfigFiles.read(:config, "next")
    assert File.read!(ctx.path) == house_toml()
  end

  test "saving the applied document shows the change and asks first", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/config/files")
    next = house_toml(model: "saved-model")

    render_hook(view, "editor_changed", %{"content" => next})
    view |> element("button", "Save") |> render_click()

    assert has_element?(view, "#confirm h2", "Save and apply omashiki?")
    assert has_element?(view, "#confirm #change-summary", "changed provider")
    assert File.read!(ctx.path) == house_toml()

    view |> element("#confirm button", "Save and apply") |> render_click()

    assert File.read!(ctx.path) == next
    assert [%{model: "saved-model"}] = Config.credentials()
    assert has_element?(view, "#reload-result", "Applied generation")
  end

  test "saving an invalid applied document writes nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/config/files")

    render_hook(view, "editor_save", %{"content" => "not [ toml"})

    refute has_element?(view, "#confirm")
    assert has_element?(view, "div", "Rejected")
    assert_push_event(view, "editor_diagnostics", %{items: [%{line: 1}]})
    assert File.read!(ctx.path) == house_toml()
  end

  test "applies a draft with its summary and the sections that need a restart", ctx do
    {:ok, doc} = ConfigFiles.create(:config, "next", from: "omashiki", author: ctx.user)
    next = house_toml(containers: 8)
    {:ok, _saved} = ConfigFiles.save(:config, "next", next, doc.hash, author: ctx.user)
    {:ok, view, _html} = live(ctx.conn, ~p"/config/files?kind=config&name=next")

    render_hook(view, "editor_changed", %{"content" => "edited = 1\n"})
    assert view |> element("button", "Apply") |> render() =~ "disabled"
    render_hook(view, "editor_changed", %{"content" => next})

    view |> element("button", "Apply") |> render_click()

    assert has_element?(view, "#confirm h2", "Apply next?")
    assert has_element?(view, "#confirm div", "Restart required")
    assert has_element?(view, "#confirm div", "[limits]")

    view |> element("#confirm button", "Apply") |> render_click()

    assert File.read!(ctx.path) == next
    assert has_element?(view, "#document-next", "applied")
    assert has_element?(view, "#reload-result", "generation")
    refute has_element?(view, "button", "Apply")
  end

  test "restores a version from history after confirmation", %{conn: conn, user: user} do
    {:ok, doc} = ConfigFiles.create(:config, "next", from: :blank, author: user)

    {:ok, %{document: doc}} =
      ConfigFiles.save(:config, "next", "first = 1\n", doc.hash, author: user)

    {:ok, _saved} = ConfigFiles.save(:config, "next", "second = 2\n", doc.hash, author: user)
    [first | _] = ConfigFiles.history(:config, "next")

    {:ok, view, _html} = live(conn, ~p"/config/files?kind=config&name=next")

    row = view |> element("#version-#{first.id}") |> render()
    assert row =~ String.slice(first.hash, 0, 8)
    assert row =~ user.username

    view |> element("#version-#{first.id} button", "Restore") |> render_click()
    assert has_element?(view, "#confirm h2", "Restore version")
    view |> element("#confirm button", "Restore") |> render_click()

    assert_push_event(view, "editor_set", %{content: "first = 1\n", readonly: false})
    assert {:ok, %{content: "first = 1\n"}} = ConfigFiles.read(:config, "next")
  end

  test "a file changed elsewhere is never overwritten; reload shows it", %{conn: conn, user: user} do
    {:ok, doc} = ConfigFiles.create(:config, "next", from: :blank, author: user)
    {:ok, view, _html} = live(conn, ~p"/config/files?kind=config&name=next")
    {:ok, _saved} = ConfigFiles.save(:config, "next", "elsewhere = 1\n", doc.hash, author: user)

    render_hook(view, "editor_save", %{"content" => "mine = 1\n"})

    assert has_element?(view, "div", "Changed elsewhere")
    assert {:ok, %{content: "elsewhere = 1\n"}} = ConfigFiles.read(:config, "next")

    view |> element("button", "Reload") |> render_click()

    assert_push_event(view, "editor_set", %{content: "elsewhere = 1\n"})
    refute has_element?(view, "div", "Changed elsewhere")
  end

  test "saving the applied task views confirms and writes the file Home reads", ctx do
    {:ok, doc} = ConfigFiles.create(:views, "mine", from: :blank, author: ctx.user)
    {:ok, _saved} = ConfigFiles.save(:views, "mine", @views, doc.hash, author: ctx.user)
    {:ok, _applied} = ConfigFiles.apply(:views, "mine", author: ctx.user)
    {:ok, view, _html} = live(ctx.conn, ~p"/config/files?kind=views")

    edited = String.replace(@views, "Mine", "Ours")
    render_hook(view, "editor_save", %{"content" => edited})
    assert has_element?(view, "#confirm", "The Home screen shows it within seconds.")
    view |> element("#confirm button", "Save and apply") |> render_click()

    assert File.read!(Path.join(ctx.root, "ui.toml")) == edited
  end

  describe "a directory that refuses writes" do
    @describetag skip: root_user?() && "root writes through file permissions"

    test "shows the files read-only and names the directory", ctx do
      File.chmod!(ctx.root, 0o555)
      on_exit(fn -> File.chmod!(ctx.root, 0o755) end)

      {:ok, view, _html} = live(ctx.conn, ~p"/config/files")

      assert has_element?(view, "div", "#{ctx.root} is not writable")
      assert has_element?(view, "div", "mount the config directory writable")
      assert has_element?(view, "#document-omashiki", "applied")
      assert has_element?(view, "#toml-editor[data-readonly=true][data-content*=limits]")
      assert has_element?(view, "button[disabled]", "Save")
      assert has_element?(view, "button[disabled]", "New")
      assert has_element?(view, "button:not([disabled])", "Check")

      render_hook(view, "editor_save", %{"content" => "a = 1\n"})
      refute has_element?(view, "#confirm")
      assert File.read!(ctx.path) == house_toml()
    end

    test "disables restore and the draft actions", ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: :blank, author: ctx.user)
      {:ok, _saved} = ConfigFiles.save(:config, "next", "a = 1\n", doc.hash, author: ctx.user)
      store = Path.join(ctx.root, ".omashiki-files/config")
      File.chmod!(store, 0o555)
      on_exit(fn -> File.chmod!(store, 0o755) end)

      {:ok, view, _html} = live(ctx.conn, ~p"/config/files?kind=config&name=next")

      assert has_element?(view, "div", "#{store} is not writable")
      assert has_element?(view, "button[disabled]", "Apply")
      assert has_element?(view, "button[disabled]", "Delete")
      assert has_element?(view, "#history button[disabled]", "Restore")
    end
  end

  describe "with login off" do
    setup do
      previous =
        Map.new([:auth_mode, OmashikiWeb.Endpoint], &{&1, Application.get_env(:omashiki, &1)})

      Application.put_env(:omashiki, :auth_mode, :none)

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> Application.delete_env(:omashiki, key)
          {key, value} -> Application.put_env(:omashiki, key, value)
        end)
      end)
    end

    test "warns that anyone reaching the house can edit it", %{conn: conn} do
      endpoint = Application.get_env(:omashiki, OmashikiWeb.Endpoint)
      http = Keyword.put(endpoint[:http], :ip, {0, 0, 0, 0})
      Application.put_env(:omashiki, OmashikiWeb.Endpoint, Keyword.put(endpoint, :http, http))

      {:ok, view, _html} = live(conn, ~p"/config/files")

      assert has_element?(view, "div", "Anyone who reaches this house can edit it")
      assert has_element?(view, "button", "Save")
    end

    test "stays quiet on loopback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config/files")
      refute has_element?(view, "div", "Anyone who reaches this house can edit it")
    end
  end
end
