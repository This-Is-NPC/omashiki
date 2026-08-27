defmodule Omashiki.Config.ReloadTest do
  @moduledoc """
  Swapping a model is a hot operation, and a rejected file is a no-op.

  These two properties are the whole contract. The first is what lets an
  operator change `[credentials].model` without restarting the core; the second
  is what makes the first safe, because `${env:VAR}` resolves at *load* — so a
  reload can fail on an unset variable, and failing halfway would leave the core
  serving a configuration that exists in no file.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Config

  @env_var "OMASHIKI_TEST_RELOAD_KEY"

  setup do
    Config.reset!()
    root = Path.join(System.tmp_dir!(), "omashiki-reload-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    path = Path.join(root, "omashiki.toml")

    on_exit(fn ->
      Config.reset!()
      System.delete_env(@env_var)
      File.rm_rf!(root)
    end)

    %{root: root, path: path}
  end

  describe "reload/1" do
    test "a model changed in the file is served to newly resolved jobs, with no restart", ctx do
      write(ctx, model: "qwen2.5-coder-1.5b-instruct")
      assert :ok = Config.load!(ctx.path)

      assert {:ok, admitted} = Config.resolve_job("app", "opencode")
      assert [%{model: "qwen2.5-coder-1.5b-instruct"}] = admitted.environment.credentials
      generation = Config.generation()
      digest = Config.current_digest()

      write(ctx, model: "qwen2.5-coder-32b-instruct")

      assert {:ok, info} = Config.reload(ctx.path)
      assert info.changed?
      assert info.generation == generation + 1
      assert info.previous_digest == digest

      assert {:ok, current} = Config.resolve_job("app", "opencode")
      assert [%{model: "qwen2.5-coder-32b-instruct"}] = current.environment.credentials
      refute Config.current_digest() == digest
    end

    # The reason the swap is safe at all. Anything already resolved holds its
    # own values, so a reload cannot move the ground under work in flight.
    test "a resolution taken before the reload keeps the values it captured", ctx do
      write(ctx, model: "old-model")
      assert :ok = Config.load!(ctx.path)
      assert {:ok, admitted} = Config.resolve_job("app", "opencode")

      write(ctx, model: "new-model")
      assert {:ok, _info} = Config.reload(ctx.path)

      assert [%{model: "old-model"}] = admitted.environment.credentials
      assert admitted.digest != Config.current_digest()
    end

    test "a reload that changes nothing still reports the generation it wrote", ctx do
      write(ctx, model: "same-model")
      assert :ok = Config.load!(ctx.path)
      digest = Config.current_digest()

      assert {:ok, info} = Config.reload(ctx.path)
      refute info.changed?
      assert info.digest == digest
    end

    # `${env:VAR}` resolves at load. That is the feature — a reload re-reads the
    # environment, which is how a rotated key or a moved model server lands —
    # and it is also why a reload can fail on a variable that is no longer set.
    test "an unset ${env:VAR} leaves the previous generation serving, unchanged", ctx do
      System.put_env(@env_var, "key-that-is-set")
      write(ctx, model: "old-model", api_key: "${env:#{@env_var}}")
      assert :ok = Config.load!(ctx.path)

      generation = Config.generation()
      digest = Config.current_digest()
      loaded_at = Config.loaded_at()

      System.delete_env(@env_var)
      write(ctx, model: "new-model", api_key: "${env:#{@env_var}}")

      assert {:error, message} = Config.reload(ctx.path)
      assert message =~ @env_var

      # Not "an error was returned" — the previous generation is still *serving*.
      # Asserted in that order on purpose: a half-applied write would strand the
      # core with no registry at all, and the resolution failing is the symptom
      # an operator would actually meet.
      assert {:ok, resolved} = Config.resolve_job("app", "opencode")

      assert [%{model: "old-model", api_key: "key-that-is-set"}] =
               resolved.environment.credentials

      assert Config.current_digest() == digest
      assert Config.generation() == generation
      assert Config.loaded_at() == loaded_at
    end

    test "a file that has become unparseable leaves the previous generation serving", ctx do
      write(ctx, model: "old-model")
      assert :ok = Config.load!(ctx.path)
      generation = Config.generation()

      File.write!(ctx.path, "this is not [ valid toml")

      assert {:error, message} = Config.reload(ctx.path)
      assert message =~ "unreadable"
      assert Config.generation() == generation
      assert {:ok, resolved} = Config.resolve_job("app", "opencode")
      assert [%{model: "old-model"}] = resolved.environment.credentials
    end

    test "a file that has gone missing leaves the previous generation serving", ctx do
      write(ctx, model: "old-model")
      assert :ok = Config.load!(ctx.path)
      generation = Config.generation()

      File.rm!(ctx.path)

      assert {:error, message} = Config.reload(ctx.path)
      assert message =~ "not found"
      assert Config.generation() == generation
      assert {:ok, _resolved} = Config.resolve_job("app", "opencode")
    end
  end

  describe "generation/0" do
    test "counts successful writes only", ctx do
      write(ctx, model: "one")
      assert :ok = Config.load!(ctx.path)
      first = Config.generation()

      assert {:ok, _info} = Config.reload(ctx.path)
      assert Config.generation() == first + 1

      File.write!(ctx.path, "broken [")
      assert {:error, _message} = Config.reload(ctx.path)
      assert Config.generation() == first + 1
    end
  end

  describe "[reload] policy" do
    test "defaults to gradual with a bounded drain when the section is absent", ctx do
      write(ctx, model: "m")
      assert :ok = Config.load!(ctx.path)

      assert %{mode: :gradual, drain_timeout_ms: drain_timeout_ms} = Config.reload_policy()
      assert is_integer(drain_timeout_ms) and drain_timeout_ms > 0
    end

    test "drain_all is selectable from the core config", ctx do
      write(ctx, model: "m", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 60000\n))
      assert :ok = Config.load!(ctx.path)

      assert %{mode: :drain_all, drain_timeout_ms: 60_000} = Config.reload_policy()
    end

    test "an unknown mode is rejected at load rather than defaulted silently", ctx do
      write(ctx, model: "m", reload: ~s(mode = "yolo"\n))

      assert_raise Config.Error, ~r/reload\.mode/, fn -> Config.load!(ctx.path) end
    end

    test "an unknown field in [reload] is rejected", ctx do
      write(ctx, model: "m", reload: ~s(strategy = "gradual"\n))

      assert_raise Config.Error, ~r/unknown fields/, fn -> Config.load!(ctx.path) end
    end

    test "a non-positive drain bound is rejected", ctx do
      write(ctx, model: "m", reload: "drain_timeout_ms = 0\n")

      assert_raise Config.Error, ~r/drain_timeout_ms/, fn -> Config.load!(ctx.path) end
    end
  end

  defp write(ctx, opts) do
    model = Keyword.fetch!(opts, :model)
    api_key = Keyword.get(opts, :api_key, "plaintext-key")
    reload = Keyword.get(opts, :reload)

    reload_section = if reload, do: "\n[reload]\n" <> reload, else: ""

    File.write!(ctx.path, """
    [limits]
    max_concurrent_containers = 4
    #{reload_section}
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
  end
end
