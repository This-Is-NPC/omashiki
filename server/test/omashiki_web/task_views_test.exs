defmodule OmashikiWeb.TaskViewsTest do
  # Not async: one test changes the path application env and OS variables.
  use ExUnit.Case, async: false

  alias OmashikiWeb.TaskViews
  alias OmashikiWeb.TaskViews.View

  @example Path.expand("../../../examples/ui.toml", __DIR__)

  setup do
    dir =
      Path.join(System.tmp_dir!(), "omashiki-task-views-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "ui.toml")}
  end

  test "several views in one file keep their declared order" do
    assert {:ok, [first, second], "failures"} =
             TaskViews.parse("""
             default_view = "failures"

             [[views]]
             name = "active"
             filter = { status = ["queued", "running"], environment = "codex" }
             fields = ["status", "title", "context.issue.url"]
             blocks = ["slots"]

             [[views]]
             name = "failures"
             title = "Failures today"
             layout = "board"
             filter = { status = "failed", since = "24h", priority = [2, 3] }
             sort = "-finished"
             limit = 20
             """)

    assert %View{
             name: "active",
             title: "active",
             layout: :list,
             group_by: nil,
             limit: 100,
             sort: {:inserted_at, :desc},
             blocks: [:slots],
             filter: %{status: ["queued", "running"], environment: ["codex"]},
             fields: ["status", "title", "context.issue.url"]
           } = first

    assert %View{
             name: "failures",
             title: "Failures today",
             layout: :board,
             group_by: :status,
             sort: {:finished_at, :desc},
             limit: 20,
             filter: %{status: ["failed"], since: 86_400, priority: [2, 3]}
           } = second
  end

  test "every problem is reported with the view that has it" do
    assert {:error, errors} =
             TaskViews.parse("""
             theme = "dark"

             [[views]]
             name = "Bad Name"
             layout = "grid"
             fields = ["status", "tokens", "status"]
             filter = { status = ["done"], since = "soon", owner = "me" }
             sort = "age"
             group_by = "user"
             limit = 0
             blocks = ["chart"]

             [[views]]
             name = "ok"

             [[views]]
             name = "ok"
             """)

    where = ~s(views[1] "Bad Name")

    assert ~s(file: unknown key "theme") in errors
    assert Enum.any?(errors, &String.starts_with?(&1, "#{where}: name: must start"))
    assert ~s(#{where}: layout: must be "list", "board", or "graph") in errors
    assert ~s(#{where}: fields: unknown field "tokens") in errors
    assert ~s(#{where}: fields: field "status" is listed more than once) in errors
    assert Enum.any?(errors, &(&1 =~ ~s(#{where}: filter: status: unknown status "done")))
    assert Enum.any?(errors, &(&1 =~ ~s(#{where}: filter: since: must be a duration)))
    assert Enum.any?(errors, &(&1 =~ ~s(#{where}: filter: owner: unknown filter key)))
    assert Enum.any?(errors, &(&1 =~ ~s(#{where}: sort: must be submitted)))
    assert Enum.any?(errors, &(&1 =~ ~s(#{where}: group_by: must be one of)))
    assert ~s(#{where}: limit: must be an integer from 1 through 500) in errors
    assert Enum.any?(errors, &(&1 =~ ~s(#{where}: blocks: must list only)))
    assert ~s(views: name "ok" is declared more than once) in errors
  end

  # A view only selects what the screen renders. Anything that sounds like an
  # action is not a key, so a file cannot ask the house to do something.
  test "a view declares no action" do
    for key <- ~w(cancel retry requeue purge command priority_override) do
      assert {:error, [message]} = TaskViews.parse(~s([[views]]\nname = "a"\n#{key} = true\n))
      assert message == ~s(views[1] "a": unknown key "#{key}")
    end
  end

  test "a graph view declares which workers it shows and takes no grouping" do
    assert {:ok, [%View{layout: :graph, show_idle_workers: false, show_stale_workers: true}], _} =
             TaskViews.parse(
               ~s([[views]]\nname = "fleet"\nlayout = "graph"\nshow_idle_workers = false\n)
             )

    assert {:error, [message]} =
             TaskViews.parse(
               ~s([[views]]\nname = "fleet"\nlayout = "graph"\ngroup_by = "status"\n)
             )

    assert message =~ "group_by: does not apply to the graph layout"

    assert {:error, [message]} =
             TaskViews.parse(~s([[views]]\nname = "list"\nshow_stale_workers = false\n))

    assert message =~ "show_stale_workers: applies only to the graph layout"

    assert {:error, [message]} =
             TaskViews.parse(
               ~s([[views]]\nname = "fleet"\nlayout = "graph"\nshow_idle_workers = "no"\n)
             )

    assert message =~ "must be true or false"
  end

  test "default_view must name a declared view" do
    assert {:error, [~s(default_view: "gone" does not name a declared view)]} =
             TaskViews.parse(~s(default_view = "gone"\n[[views]]\nname = "a"\n))
  end

  test "a file needs at least one view and valid TOML" do
    assert {:error, ["views: declare at least one [[views]] table"]} = TaskViews.parse("")

    assert {:error, ["views: must be an array of tables written as [[views]]"]} =
             TaskViews.parse(~s(views = "x"\n))

    assert {:error, ["invalid TOML: " <> _reason]} = TaskViews.parse("[[views]\nname =")
  end

  test "context fields accept dotted paths only" do
    assert {:ok, [%View{fields: ["context.issue_url", "context.a.b-c"]}], "a"} =
             TaskViews.parse(
               ~s([[views]]\nname = "a"\nfields = ["context.issue_url", "context.a.b-c"]\n)
             )

    for field <- ["context.", "context.a..b", "context.a b"] do
      assert {:error, [message]} =
               TaskViews.parse(~s([[views]]\nname = "a"\nfields = ["#{field}"]\n))

      assert message =~ ~s(unknown field "#{field}")
    end
  end

  test "the built-in views and the example file are valid" do
    assert {[%View{name: "board", layout: :board} | _], "board"} = TaskViews.builtin()
    assert {:ok, [_ | _], "board"} = @example |> File.read!() |> TaskViews.parse()
  end

  test "a missing file uses the built-in views", %{path: path} do
    state = TaskViews.load(path)

    assert state.source == :builtin
    assert state.errors == []
    assert {:ok, %View{name: "board"}} = TaskViews.find(state, nil)
  end

  test "a changed file applies on refresh and a rejected change keeps the last valid views",
       %{path: path} do
    File.write!(path, ~s([[views]]\nname = "mine"\n))
    state = TaskViews.load(path)
    assert state.source == :file
    assert [%View{name: "mine"}] = state.views

    File.write!(path, ~s([[views]]\nname = "mine"\nlayout = "grid"\n))
    state = TaskViews.refresh(state)
    assert [%View{name: "mine", layout: :list}] = state.views
    assert [error] = state.errors
    assert error =~ "layout"

    File.write!(path, ~s([[views]]\nname = "fixed"\n))
    state = TaskViews.refresh(state)
    assert [%View{name: "fixed"}] = state.views
    assert state.errors == []

    File.rm!(path)
    state = TaskViews.refresh(state)
    assert state.source == :builtin
    assert state.errors == []
  end

  test "an unreadable path reports the reason and keeps the views", %{path: path} do
    File.mkdir_p!(path)
    state = TaskViews.load(path)

    assert state.source == :builtin
    assert [error] = state.errors
    assert error =~ "cannot read #{path}"
  end

  test "an unchanged file is not applied again", %{path: path} do
    File.write!(path, ~s([[views]]\nname = "mine"\n))
    state = TaskViews.load(path)

    assert TaskViews.refresh(state) == state
  end

  test "an undeclared view name falls back to the default view", %{path: path} do
    File.write!(path, ~s(default_view = "b"\n[[views]]\nname = "a"\n[[views]]\nname = "b"\n))
    state = TaskViews.load(path)

    assert {:ok, %View{name: "a"}} = TaskViews.find(state, "a")
    assert {:ok, %View{name: "b"}} = TaskViews.find(state, nil)
    assert {:fallback, %View{name: "b"}} = TaskViews.find(state, "missing")
  end

  test "the path is the application env, then OMASHIKI_UI_CONFIG, then XDG_CONFIG_HOME" do
    previous_path = Application.get_env(:omashiki, :ui_config_path)
    previous_env = System.get_env("OMASHIKI_UI_CONFIG")
    previous_xdg = System.get_env("XDG_CONFIG_HOME")

    on_exit(fn ->
      Application.put_env(:omashiki, :ui_config_path, previous_path)
      restore_env("OMASHIKI_UI_CONFIG", previous_env)
      restore_env("XDG_CONFIG_HOME", previous_xdg)
    end)

    Application.put_env(:omashiki, :ui_config_path, "/srv/app/ui.toml")
    System.put_env("OMASHIKI_UI_CONFIG", "/srv/env/ui.toml")
    System.put_env("XDG_CONFIG_HOME", "/srv/xdg")
    assert TaskViews.path() == "/srv/app/ui.toml"

    Application.delete_env(:omashiki, :ui_config_path)
    assert TaskViews.path() == "/srv/env/ui.toml"

    System.delete_env("OMASHIKI_UI_CONFIG")
    assert TaskViews.path() == "/srv/xdg/omashiki/ui.toml"

    System.delete_env("XDG_CONFIG_HOME")
    assert TaskViews.path() == Path.expand("~/.config/omashiki/ui.toml")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
