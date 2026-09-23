defmodule Omashiki.Runtime.HostCredentialsTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config.HostCredential
  alias Omashiki.Harness.Context
  alias Omashiki.Plugin.{Interpreter, Loader, Preset}
  alias Omashiki.Runtime.HostCredentials
  alias Omashiki.Runtime.Spec

  @house "this-house"
  @other "another-house"

  setup do
    origins =
      Path.join(System.tmp_dir!(), "omashiki-origins-#{System.unique_integer([:positive])}")

    File.mkdir_p!(origins)
    auth = Path.join(origins, "auth.json")
    config = Path.join(origins, "opencode.json")
    File.write!(auth, ~s({"token":"live"}))
    File.write!(config, "{}")

    on_exit(fn ->
      File.rm_rf!(origins)
      File.rm_rf!(HostCredentials.root())
    end)

    %{origins: origins, auth: auth, config: config}
  end

  test "copies every origin into a private per-attempt directory", ctx do
    scope = scope()

    assert {:ok, materialized} =
             HostCredentials.materialize(@house, scope, environment(ctx.auth, ctx.config))

    assert materialized.dir == HostCredentials.scope_dir(@house, scope)
    assert materialized.binds == ["#{materialized.dir}:/run/omashiki/state"]

    assert materialized.mounts == [
             {Path.join(materialized.dir, "auth.json"), "/run/omashiki/state/auth.json", false},
             {Path.join(materialized.dir, "opencode.json"), "/run/omashiki/state/opencode.json",
              false}
           ]

    assert File.read!(Path.join(materialized.dir, "auth.json")) == ~s({"token":"live"})
    assert mode(materialized.dir) == 0o700
    assert mode(Path.join(materialized.dir, "auth.json")) == 0o600
  end

  test "gives concurrent attempts independent copies of a rewritten origin", ctx do
    first = scope()
    second = scope()

    assert {:ok, one} = HostCredentials.materialize(@house, first, environment(ctx.auth))
    assert {:ok, two} = HostCredentials.materialize(@house, second, environment(ctx.auth))

    refute one.dir == two.dir
    File.write!(Path.join(one.dir, "auth.json"), ~s({"token":"refreshed"}))

    assert File.read!(Path.join(two.dir, "auth.json")) == ~s({"token":"live"})
    assert File.read!(ctx.auth) == ~s({"token":"live"})
  end

  test "picks up a rotated origin without a reload", ctx do
    assert {:ok, before} = HostCredentials.materialize(@house, scope(), environment(ctx.auth))
    assert File.read!(Path.join(before.dir, "auth.json")) == ~s({"token":"live"})

    File.write!(ctx.auth, ~s({"token":"rotated"}))

    assert {:ok, later} = HostCredentials.materialize(@house, scope(), environment(ctx.auth))
    assert File.read!(Path.join(later.dir, "auth.json")) == ~s({"token":"rotated"})
  end

  test "fails the attempt and leaves nothing behind when an origin is missing", ctx do
    scope = scope()
    File.rm!(ctx.auth)

    assert {:error, {:host_credential_unavailable, "opencode-local", "auth.json"}} =
             HostCredentials.materialize(@house, scope, environment(ctx.auth))

    refute File.exists?(HostCredentials.scope_dir(@house, scope))
  end

  # `~/` resolves against the home of the process that copies — this one — so a
  # worker with a different Unix user reads its own login, never the manager's.
  test "expands ~/ against the home of the copying process", ctx do
    File.mkdir_p!(Path.join(ctx.origins, ".harness"))
    File.write!(Path.join(ctx.origins, ".harness/login.json"), ~s({"login":"worker"}))

    with_home(ctx.origins, fn ->
      assert {:ok, materialized} =
               HostCredentials.materialize(@house, scope(), environment("~/.harness/login.json"))

      assert File.read!(Path.join(materialized.dir, "auth.json")) == ~s({"login":"worker"})
    end)
  end

  test "fails the attempt when this home lacks the declared file", ctx do
    scope = scope()

    with_home(ctx.origins, fn ->
      assert {:error, {:host_credential_unavailable, "opencode-local", "auth.json"}} =
               HostCredentials.materialize(@house, scope, environment("~/.harness/login.json"))
    end)

    refute File.exists?(HostCredentials.scope_dir(@house, scope))
  end

  test "readable/1 checks an origin the way an attempt would copy it", ctx do
    assert :ok = HostCredentials.readable(ctx.auth)
    assert {:error, :enoent} = HostCredentials.readable(ctx.origins)

    with_home(ctx.origins, fn ->
      assert :ok = HostCredentials.readable("~/auth.json")
      assert {:error, :enoent} = HostCredentials.readable("~/.harness/login.json")
    end)
  end

  test "rejects two credentials fighting for one container file", ctx do
    environment = %{
      host_credentials: [
        %{name: "one", files: %{"auth.json" => ctx.auth}},
        %{name: "two", files: %{"auth.json" => ctx.auth}}
      ]
    }

    assert {:error, {:host_credential_conflict, "auth.json"}} =
             HostCredentials.materialize(@house, scope(), environment)
  end

  test "materializes nothing for an environment without host credentials" do
    assert {:ok, %{dir: nil, binds: [], mounts: []}} =
             HostCredentials.materialize(@house, scope(), %{"host_credentials" => []})
  end

  test "discards one scope and sweeps every inactive scope of its house", ctx do
    active = scope()
    stale = scope()
    theirs = scope()

    assert {:ok, _} = HostCredentials.materialize(@house, active, environment(ctx.auth))
    assert {:ok, _} = HostCredentials.materialize(@house, stale, environment(ctx.auth))
    assert {:ok, _} = HostCredentials.materialize(@other, theirs, environment(ctx.auth))

    # The root is shared with everything else in /dev/shm.
    foreign = Path.join(HostCredentials.root(), "not-omashiki")
    File.mkdir_p!(foreign)

    HostCredentials.sweep([@house], [active])

    assert File.dir?(HostCredentials.scope_dir(@house, active))
    refute File.exists?(HostCredentials.scope_dir(@house, stale))
    assert File.dir?(HostCredentials.scope_dir(@other, theirs))
    assert File.dir?(foreign)

    HostCredentials.discard(@house, active)
    refute File.exists?(HostCredentials.scope_dir(@house, active))
    assert HostCredentials.discard(@house, active) == :ok
  end

  test "sweeps each house a worker serves by its own attempts", ctx do
    [mine, stale, kept_elsewhere] = Enum.map(1..3, fn _ -> scope() end)

    assert {:ok, _} = HostCredentials.materialize(@house, mine, environment(ctx.auth))
    assert {:ok, _} = HostCredentials.materialize(@house, stale, environment(ctx.auth))
    assert {:ok, _} = HostCredentials.materialize(@other, stale, environment(ctx.auth))
    assert {:ok, _} = HostCredentials.materialize("third", kept_elsewhere, environment(ctx.auth))

    HostCredentials.sweep([@house, @other], [mine])

    assert File.dir?(HostCredentials.scope_dir(@house, mine))
    refute File.exists?(HostCredentials.scope_dir(@house, stale))
    refute File.exists?(HostCredentials.scope_dir(@other, stale))
    assert File.dir?(HostCredentials.scope_dir("third", kept_elsewhere))
  end

  test "refuses an owner that could not be read back from the directory name" do
    assert_raise ArgumentError, fn -> HostCredentials.scope_dir("a@b", scope()) end
    assert_raise ArgumentError, fn -> HostCredentials.scope_dir(@house, "../job") end
  end

  test "satisfies the Claude harness writable-credentials mount", ctx do
    credentials = Path.join(ctx.origins, "claude.json")
    File.write!(credentials, ~s({"claude":"live"}))

    environment = %{
      host_credentials: [
        %HostCredential{
          name: "claude-local",
          kind: "claude-code",
          files: %{"claude-credentials.json" => credentials}
        }
      ]
    }

    assert {:ok, materialized} = HostCredentials.materialize(@house, scope(), environment)

    context = %Context{
      job: %{payload: %{"instruction" => "go"}},
      runtime_mounts: materialized.mounts
    }

    assert {:ok, _plan} = Interpreter.prepare(claude_profile(), context)
  end

  defp with_home(home, fun) do
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    try do
      fun.()
    after
      System.put_env("HOME", previous)
    end
  end

  defp environment(auth) do
    %{host_credentials: [%{name: "opencode-local", files: %{"auth.json" => auth}}]}
  end

  # String-keyed, exactly like the environment snapshot read back from the job.
  defp environment(auth, config) do
    %{
      "host_credentials" => [
        %{
          "name" => "opencode-local",
          "files" => %{"auth.json" => auth, "opencode.json" => config}
        }
      ]
    }
  end

  defp claude_profile do
    manifest = Loader.shipped_dir() |> Loader.load!() |> Map.fetch!("claude-code")

    %Preset{
      name: "claude-code",
      adapter: Interpreter,
      plugin: "claude-code",
      options: %{},
      runtime: %Spec{
        name: "docker.runc.debian",
        backend: "docker",
        handler: "runc",
        distribution: "debian",
        plugin: "claude-code",
        image: "agent"
      },
      launch_plan: nil,
      manifest: manifest
    }
  end

  defp scope, do: "job-#{System.unique_integer([:positive])}"

  defp mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end
