defmodule Omashiki.Config.RolloutTest do
  @moduledoc """
  The two modes, and the bound on the one that waits.

  `:gradual` is the interesting case only in what it *does not* do: it never
  closes admission, because a mixed fleet is already correct — every job holds
  the snapshot it was admitted with. `:drain_all` is the one with a state
  machine, and the property worth pinning is what happens when the drain does
  not finish: nothing is applied, nothing is cancelled, and admission reopens.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.Rollout

  setup do
    Config.reset!()
    root = Path.join(System.tmp_dir!(), "omashiki-rollout-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    path = Path.join(root, "omashiki.toml")

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, path: path}
  end

  describe "gradual" do
    test "swaps the live generation immediately and never closes admission", ctx do
      write(ctx, model: "old-model")
      rollout = start_rollout(ctx, counter: fn -> 3 end)
      assert :ok = Config.load!(ctx.path)
      generation = Config.generation()

      write(ctx, model: "new-model")

      assert {:ok, info} = Rollout.reload(rollout)
      assert info.changed?
      assert info.generation == generation + 1
      assert Rollout.admission_open?(rollout)

      assert {:ok, resolved} = Config.resolve_job("app", "opencode")
      assert [%{model: "new-model"}] = resolved.environment.credentials
    end

    test "a rejected file is reported and the previous generation keeps serving", ctx do
      write(ctx, model: "old-model")
      rollout = start_rollout(ctx, counter: fn -> 0 end)
      assert :ok = Config.load!(ctx.path)
      generation = Config.generation()

      File.write!(ctx.path, "not [ toml")

      assert {:error, message} = Rollout.reload(rollout)
      assert message =~ "unreadable"
      assert Config.generation() == generation
      assert Rollout.admission_open?(rollout)
      assert {:ok, _resolved} = Config.resolve_job("app", "opencode")
    end
  end

  describe "drain_all" do
    test "closes admission while attempts remain, then swaps once the fleet empties", ctx do
      counter = start_counter(2)
      write(ctx, model: "old-model", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 30000\n))
      rollout = start_rollout(ctx, counter: counter_fun(counter), poll_ms: 10)
      assert :ok = Config.load!(ctx.path)
      generation = Config.generation()

      write(ctx, model: "new-model", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 30000\n))

      # The reply is immediate: a drain can take as long as the longest attempt.
      assert {:ok, :draining} = Rollout.reload(rollout)
      refute Rollout.admission_open?(rollout)
      assert Config.generation() == generation

      # Still nothing applied while work is in flight.
      set_counter(counter, 1)
      Process.sleep(50)
      refute Rollout.admission_open?(rollout)
      assert Config.generation() == generation

      set_counter(counter, 0)
      assert eventually(fn -> Rollout.admission_open?(rollout) end)

      assert Config.generation() == generation + 1
      assert {:ok, resolved} = Config.resolve_job("app", "opencode")
      assert [%{model: "new-model"}] = resolved.environment.credentials
    end

    # The bound. Cancelling a user's job so an operator's configuration change
    # can land is a product decision this module does not make, so the drain is
    # abandoned instead: admission reopens, and the file is not applied.
    test "a drain that outlives its bound applies nothing and reopens admission", ctx do
      write(ctx, model: "old-model", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 30\n))
      rollout = start_rollout(ctx, counter: fn -> 1 end, poll_ms: 5)
      assert :ok = Config.load!(ctx.path)
      generation = Config.generation()

      write(ctx, model: "new-model", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 30\n))

      assert {:ok, :draining} = Rollout.reload(rollout)
      assert eventually(fn -> Rollout.admission_open?(rollout) end)

      assert Config.generation() == generation
      assert {:ok, resolved} = Config.resolve_job("app", "opencode")
      assert [%{model: "old-model"}] = resolved.environment.credentials
      assert %{last: {:error, :drain_timeout}} = Rollout.status(rollout)
    end

    test "a second reload during a drain is refused rather than queued", ctx do
      write(ctx, model: "old-model", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 30000\n))
      rollout = start_rollout(ctx, counter: fn -> 1 end, poll_ms: 50)
      assert :ok = Config.load!(ctx.path)

      assert {:ok, :draining} = Rollout.reload(rollout)
      assert {:error, :drain_in_progress} = Rollout.reload(rollout)
    end
  end

  describe "status/0" do
    test "reports the declared mode and the drain it is running", ctx do
      write(ctx, model: "m", reload: ~s(mode = "drain_all"\ndrain_timeout_ms = 30000\n))
      rollout = start_rollout(ctx, counter: fn -> 4 end, poll_ms: 1_000)
      assert :ok = Config.load!(ctx.path)

      assert %{mode: :drain_all, draining?: false} = Rollout.status(rollout)

      assert {:ok, :draining} = Rollout.reload(rollout)

      assert %{draining?: true, waiting_for: 4, drain_timeout_ms: 30_000} =
               Rollout.status(rollout)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp start_rollout(ctx, opts) do
    opts = Keyword.merge([name: nil, path: ctx.path], opts)
    pid = start_supervised!({Rollout, opts}, id: {Rollout, System.unique_integer([:positive])})
    pid
  end

  defp start_counter(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp counter_fun(agent), do: fn -> Agent.get(agent, & &1) end

  defp set_counter(agent, value), do: Agent.update(agent, fn _ -> value end)

  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  defp write(ctx, opts) do
    model = Keyword.fetch!(opts, :model)
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
    api_key = "plaintext-key"

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
