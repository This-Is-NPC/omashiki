defmodule Omashiki.Runtime.HostCredentialsTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config.HostCredential
  alias Omashiki.Harness.Context
  alias Omashiki.Plugin.{Interpreter, Loader, Preset}
  alias Omashiki.Runtime.HostCredentials
  alias Omashiki.Runtime.Spec

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
             HostCredentials.materialize(scope, environment(ctx.auth, ctx.config))

    assert materialized.dir == HostCredentials.scope_dir(scope)
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

    assert {:ok, one} = HostCredentials.materialize(first, environment(ctx.auth))
    assert {:ok, two} = HostCredentials.materialize(second, environment(ctx.auth))

    refute one.dir == two.dir
    File.write!(Path.join(one.dir, "auth.json"), ~s({"token":"refreshed"}))

    assert File.read!(Path.join(two.dir, "auth.json")) == ~s({"token":"live"})
    assert File.read!(ctx.auth) == ~s({"token":"live"})
  end

  test "picks up a rotated origin without a reload", ctx do
    assert {:ok, before} = HostCredentials.materialize(scope(), environment(ctx.auth))
    assert File.read!(Path.join(before.dir, "auth.json")) == ~s({"token":"live"})

    File.write!(ctx.auth, ~s({"token":"rotated"}))

    assert {:ok, later} = HostCredentials.materialize(scope(), environment(ctx.auth))
    assert File.read!(Path.join(later.dir, "auth.json")) == ~s({"token":"rotated"})
  end

  test "fails the attempt and leaves nothing behind when an origin is missing", ctx do
    scope = scope()
    File.rm!(ctx.auth)

    assert {:error, {:host_credential_unavailable, "opencode-local", "auth.json"}} =
             HostCredentials.materialize(scope, environment(ctx.auth))

    refute File.exists?(HostCredentials.scope_dir(scope))
  end

  test "rejects two credentials fighting for one container file", ctx do
    environment = %{
      host_credentials: [
        %{name: "one", files: %{"auth.json" => ctx.auth}},
        %{name: "two", files: %{"auth.json" => ctx.auth}}
      ]
    }

    assert {:error, {:host_credential_conflict, "auth.json"}} =
             HostCredentials.materialize(scope(), environment)
  end

  test "materializes nothing for an environment without host credentials" do
    assert {:ok, %{dir: nil, binds: [], mounts: []}} =
             HostCredentials.materialize(scope(), %{"host_credentials" => []})
  end

  test "discards one scope and sweeps every inactive scope", ctx do
    active = scope()
    stale = scope()

    assert {:ok, _} = HostCredentials.materialize(active, environment(ctx.auth))
    assert {:ok, _} = HostCredentials.materialize(stale, environment(ctx.auth))

    HostCredentials.sweep([active])

    assert File.dir?(HostCredentials.scope_dir(active))
    refute File.exists?(HostCredentials.scope_dir(stale))

    HostCredentials.discard(active)
    refute File.exists?(HostCredentials.scope_dir(active))
    assert HostCredentials.discard(active) == :ok
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

    assert {:ok, materialized} = HostCredentials.materialize(scope(), environment)

    context = %Context{
      job: %{payload: %{"instruction" => "go"}},
      runtime_mounts: materialized.mounts
    }

    assert {:ok, _plan} = Interpreter.prepare(claude_profile(), context)
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

  @plugins_dir Path.expand("../../../../plugins", __DIR__)

  defp claude_profile do
    manifest = @plugins_dir |> Loader.load!() |> Map.fetch!("claude-code")

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
