defmodule Omashiki.Config.HostCredentialTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.{Environment, Error, HostCredential}
  alias Omashiki.Credentials.Credential

  setup do
    Config.reset!()

    root =
      Path.join(
        System.tmp_dir!(),
        "omashiki-host-credential-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    origins = Path.join(root, "origins")
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    File.mkdir_p!(origins)
    File.write!(Path.join(origins, "auth.json"), ~s({"anthropic":"live"}))
    File.write!(Path.join(origins, "opencode.json"), "{}")

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, repo: repo, origins: origins}
  end

  test "resolves a declared host credential from the environment credential list", ctx do
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))

    assert [%HostCredential{name: "opencode-local", kind: "opencode", files: files}] =
             Config.host_credentials()

    assert files == %{
             "auth.json" => Path.join(ctx.origins, "auth.json"),
             "opencode.json" => Path.join(ctx.origins, "opencode.json")
           }

    assert [%Environment{credentials: [], host_credentials: [%HostCredential{}]}] =
             Config.environments()

    assert %HostCredential{} = Config.get_host_credential("opencode-local")
  end

  test "keeps LLM gateway credentials in their own resolved list", ctx do
    configured =
      ctx
      |> fixture()
      |> put_in(
        ["credentials"],
        %{"provider" => %{"provider" => "openai_compat", "model" => "m", "api_key" => "secret"}}
      )
      |> put_in(
        ["environments", "opencode", "credentials"],
        ["provider", "opencode-local"]
      )

    assert :ok = Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))

    assert [
             %Environment{
               credentials: [%Credential{name: "provider"}],
               host_credentials: [%HostCredential{name: "opencode-local"}]
             }
           ] = Config.environments()
  end

  test "a missing origin never blocks the boot", ctx do
    File.rm!(Path.join(ctx.origins, "auth.json"))

    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    assert [%HostCredential{name: "opencode-local"}] = Config.host_credentials()
  end

  test "expands a home-relative origin outside the configuration root", ctx do
    configured =
      put_in(
        fixture(ctx),
        ["host_credentials", "opencode-local", "auth"],
        "~/.local/share/opencode/auth.json"
      )

    assert :ok = Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))

    assert %{"auth.json" => path} = hd(Config.host_credentials()).files
    assert path == Path.join(System.user_home!(), ".local/share/opencode/auth.json")
  end

  test "rejects an unknown kind, unknown field, or missing origin field", ctx do
    invalid = %{
      ~r/kind must be one of/ =>
        put_in(fixture(ctx), ["host_credentials", "opencode-local", "kind"], "aider"),
      ~r/unknown fields/ =>
        put_in(fixture(ctx), ["host_credentials", "opencode-local", "token"], "x"),
      ~r/missing required field "auth"/ =>
        pop_in(fixture(ctx), ["host_credentials", "opencode-local", "auth"]) |> elem(1)
    }

    for {message, configured} <- invalid do
      assert_raise Error, message, fn ->
        Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))
      end
    end
  end

  test "rejects a name declared as both a gateway and a host credential", ctx do
    configured =
      put_in(
        fixture(ctx),
        ["credentials"],
        %{
          "opencode-local" => %{
            "provider" => "openai_compat",
            "model" => "m",
            "api_key" => "secret"
          }
        }
      )

    assert_raise Error, ~r/declared twice/, fn ->
      Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects an unknown credential name", ctx do
    configured = put_in(fixture(ctx), ["environments", "opencode", "credentials"], ["nope"])

    assert_raise Error, ~r/unknown credential "nope"/, fn ->
      Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "keeps origins out of inspected output", ctx do
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))

    inspected = inspect(hd(Config.host_credentials()))
    assert inspected =~ "opencode-local"
    refute inspected =~ ctx.origins
  end

  test "leaves the containment and existence rules for regular mounts intact", ctx do
    outside =
      Path.join(System.tmp_dir!(), "omashiki-outside-#{System.unique_integer([:positive])}")

    File.write!(outside, "{}")
    on_exit(fn -> File.rm(outside) end)

    escaping =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "mounts"],
        [%{"source" => outside, "target" => "/run/omashiki/a.json"}]
      )

    assert_raise Error, ~r/must stay inside the configuration root/, fn ->
      Config.load_map!(escaping, path: Path.join(ctx.root, "omashiki.toml"))
    end

    missing =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "mounts"],
        [%{"source" => "gone.json", "target" => "/run/omashiki/a.json"}]
      )

    assert_raise Error, ~r/must exist without symlink components/, fn ->
      Config.load_map!(missing, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  defp fixture(ctx) do
    %{
      "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "master"}},
      "presets" => %{
        "opencode" => %{"plugin" => "opencode", "options" => %{}}
      },
      "host_credentials" => %{
        "opencode-local" => %{
          "kind" => "opencode",
          "auth" => Path.join(ctx.origins, "auth.json"),
          "config" => Path.join(ctx.origins, "opencode.json")
        }
      },
      "environments" => %{
        "opencode" => %{
          "isolation" => "docker",
          "image" => "omashiki/agent:latest",
          "sink" => "git",
          "packages" => [],
          "preset" => "opencode",
          "executables" => ["git"],
          "credentials" => ["opencode-local"],
          "timeout_ms" => 900_000,
          "mounts" => [],
          "pre_steps" => [],
          "post_steps" => [],
          "network" => "none",
          "resources" => %{"cpus" => 2.0, "memory" => "2GB", "pids" => 256}
        }
      }
    }
  end
end
