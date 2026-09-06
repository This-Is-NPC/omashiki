defmodule Omashiki.Config.IncludeTest do
  @moduledoc """
  A house is one file or several; the snapshot is the same.

  `include` is a loader concern. Nothing downstream — registry, digest,
  admission — can tell a split house from a monolith, which is the property
  every test here pins: same digest, or a loud failure at load.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Config
  import Omashiki.Fixtures

  setup do
    Config.reset!()
    root = Path.join(System.tmp_dir!(), "omashiki-include-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(root)
    copy_plugins!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, path: Path.join(root, "omashiki.toml")}
  end

  describe "a house with no include" do
    test "loads exactly as before", ctx do
      File.write!(ctx.path, infra() <> presets() <> credentials() <> environments())
      assert :ok = Config.load!(ctx.path)
      assert {:ok, _} = Config.resolve_job("app", "opencode")
    end
  end

  describe "a split house" do
    test "produces the same digest as the monolith", ctx do
      File.write!(ctx.path, infra() <> presets() <> credentials() <> environments())
      assert :ok = Config.load!(ctx.path)
      monolith = Config.current_digest()
      Config.reset!()

      File.mkdir_p!(Path.join(ctx.root, "presets"))
      File.write!(Path.join(ctx.root, "presets/opencode.toml"), presets())
      File.write!(Path.join(ctx.root, "credentials.toml"), credentials())

      File.write!(
        ctx.path,
        ~s(include = ["presets", "credentials.toml"]\n) <> infra() <> environments()
      )

      assert :ok = Config.load!(ctx.path)
      assert Config.current_digest() == monolith
      assert {:ok, _} = Config.resolve_job("app", "opencode")
    end

    test "a directory entry loads every *.toml inside it and nothing else", ctx do
      dir = Path.join(ctx.root, "pieces")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "presets.toml"), presets())
      File.write!(Path.join(dir, "credentials.toml"), credentials())
      File.write!(Path.join(dir, "notes.md"), "not [ toml")

      File.write!(ctx.path, ~s(include = ["pieces"]\n) <> infra() <> environments())

      assert :ok = Config.load!(ctx.path)
      assert [%{name: "opencode"}] = Config.presets()
    end

    test "reload picks up a change made in a piece", ctx do
      File.write!(Path.join(ctx.root, "credentials.toml"), credentials("old-model"))

      File.write!(
        ctx.path,
        ~s(include = ["credentials.toml"]\n) <> infra() <> presets() <> environments()
      )

      assert :ok = Config.load!(ctx.path)
      digest = Config.current_digest()

      File.write!(Path.join(ctx.root, "credentials.toml"), credentials("new-model"))
      assert {:ok, info} = Config.reload(ctx.path)
      assert info.changed?
      refute Config.current_digest() == digest
    end
  end

  describe "failures leave the previous generation serving" do
    setup ctx do
      File.write!(ctx.path, infra() <> presets() <> credentials() <> environments())
      assert :ok = Config.load!(ctx.path)
      %{generation: Config.generation()}
    end

    test "the same name in two places is a collision, not an overlay", ctx do
      File.write!(Path.join(ctx.root, "presets.toml"), presets())

      File.write!(
        ctx.path,
        ~s(include = ["presets.toml"]\n) <>
          infra() <> presets() <> credentials() <> environments()
      )

      assert_raise Config.Error, ~r/\[presets\.opencode\] is declared more than once/, fn ->
        Config.load!(ctx.path)
      end

      assert Config.generation() == ctx.generation
    end

    test "a path outside the config directory is rejected", ctx do
      outside =
        Path.join(
          System.tmp_dir!(),
          "omashiki-outside-#{System.unique_integer([:positive])}.toml"
        )

      File.write!(outside, presets())
      on_exit(fn -> File.rm_rf!(outside) end)

      File.write!(ctx.path, ~s(include = ["../#{Path.basename(outside)}"]\n) <> infra())

      assert_raise Config.Error, ~r/escapes the config directory/, fn ->
        Config.load!(ctx.path)
      end

      File.write!(ctx.path, ~s(include = ["#{outside}"]\n) <> infra())

      assert_raise Config.Error, ~r/must be a path relative/, fn -> Config.load!(ctx.path) end
      assert Config.generation() == ctx.generation
    end

    test "a piece may not include other pieces", ctx do
      File.write!(Path.join(ctx.root, "piece.toml"), ~s(include = ["other.toml"]\n))
      File.write!(ctx.path, ~s(include = ["piece.toml"]\n) <> infra())

      assert_raise Config.Error, ~r/may not include other pieces/, fn ->
        Config.load!(ctx.path)
      end
    end

    test "infrastructure sections must stay on the root", ctx do
      File.write!(Path.join(ctx.root, "limits.toml"), "[limits]\nmax_concurrent_containers = 2\n")
      File.write!(ctx.path, ~s(include = ["limits.toml"]\n) <> infra())

      assert_raise Config.Error, ~r/\[limits\] must stay in omashiki.toml/, fn ->
        Config.load!(ctx.path)
      end
    end

    test "a missing piece fails the load", ctx do
      File.write!(ctx.path, ~s(include = ["nope.toml"]\n) <> infra())

      assert_raise Config.Error, ~r/not found/, fn -> Config.load!(ctx.path) end
    end

    test "an unparseable piece fails the load", ctx do
      File.write!(Path.join(ctx.root, "bad.toml"), "not [ toml")
      File.write!(ctx.path, ~s(include = ["bad.toml"]\n) <> infra())

      assert_raise Config.Error, ~r/bad\.toml is unreadable/, fn -> Config.load!(ctx.path) end
    end

    test "include must be an array of strings", ctx do
      File.write!(ctx.path, ~s(include = "presets"\n) <> infra())

      assert_raise Config.Error, ~r/include must be an array/, fn -> Config.load!(ctx.path) end
    end
  end

  defp infra do
    """
    [limits]
    max_concurrent_containers = 4

    [repositories.app]
    path = "repo"
    base_branch = "main"

    [runtimes.docker.runc.debian.images]
    opencode = "omashiki/agent:latest"
    """
  end

  defp presets do
    """
    [presets.opencode]
    plugin = "opencode"
    """
  end

  defp credentials(model \\ "some-model") do
    """
    [credentials.provider]
    provider = "openai_compat"
    model = "#{model}"
    api_key = "plaintext-key"
    """
  end

  defp environments do
    """
    [environments.opencode]
    runtime = "docker.runc.debian"
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
    """
  end
end
