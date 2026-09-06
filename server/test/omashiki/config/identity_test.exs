defmodule Omashiki.Config.IdentityTest do
  @moduledoc """
  The agent has a face, declared in the house, worn by the preset.

  An identity is declared once under `[identities.*]` and attached to a
  preset by name. The private key resolves at load and lives only in the live
  snapshot; everything that leaves the house — preset, registry snapshot,
  admitted environment — carries the public view.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.{Error, Identity}
  alias Omashiki.Plugin.Preset

  @env_var "OMASHIKI_TEST_GITHUB_APP_KEY"
  @key "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----"

  setup do
    Config.reset!()
    System.put_env(@env_var, @key)

    root = Path.join(System.tmp_dir!(), "omashiki-identity-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)

    on_exit(fn ->
      Config.reset!()
      System.delete_env(@env_var)
      File.rm_rf!(root)
    end)

    %{root: root, path: Path.join(root, "omashiki.toml")}
  end

  test "the to-be example loads: ana-bot worn by presets.reviewer", ctx do
    assert :ok = Config.load_map!(fixture(), path: ctx.path)

    assert [%Identity{name: "ana-bot", kind: "github-app", app_id: "123456"} = identity] =
             Config.identities()

    assert identity.installation_id == "987654"
    assert identity.private_key == @key
    assert Config.get_identity("ana-bot") == identity
    assert Config.get_identity("nobody") == nil

    assert [%Preset{name: "reviewer", identities: [public]}] = Config.presets()
    assert public == Identity.public(identity)
    refute Map.has_key?(public, :private_key)
  end

  test "two presets can wear the same identity", ctx do
    configured =
      put_in(fixture(), ["presets", "triage"], %{
        "plugin" => "opencode",
        "identities" => ["ana-bot"]
      })

    assert :ok = Config.load_map!(configured, path: ctx.path)

    assert [%Preset{name: "reviewer"} = one, %Preset{name: "triage"} = two] = Config.presets()
    assert one.identities == two.identities
  end

  test "a house with zero identities loads and presets default to none", ctx do
    configured =
      fixture()
      |> Map.delete("identities")
      |> update_in(["presets", "reviewer"], &Map.delete(&1, "identities"))

    assert :ok = Config.load_map!(configured, path: ctx.path)
    assert Config.identities() == []
    assert [%Preset{identities: []}] = Config.presets()
  end

  test "the key never leaves the house: registry snapshot and inspect are clean", ctx do
    assert :ok = Config.load_map!(fixture(), path: ctx.path)

    refute inspect(Config.current_snapshot()) =~ "PRIVATE KEY"
    refute inspect(Config.environments()) =~ "PRIVATE KEY"
    refute inspect(Config.identities()) =~ "PRIVATE KEY"
  end

  test "an identity changes the digest only through its public view", ctx do
    assert :ok = Config.load_map!(fixture(), path: ctx.path)
    digest = Config.current_digest()

    System.put_env(@env_var, @key <> "\nrotated")
    assert :ok = Config.load_map!(fixture(), path: ctx.path)
    assert Config.current_digest() == digest

    assert :ok =
             Config.load_map!(put_in(fixture(), ["identities", "ana-bot", "app_id"], "999"),
               path: ctx.path
             )

    refute Config.current_digest() == digest
  end

  test "a preset naming an unknown identity fails the boot", ctx do
    configured = put_in(fixture(), ["presets", "reviewer", "identities"], ["ana-bot", "ghost"])

    assert_raise Error,
                 ~r/presets\.reviewer\.identities references unknown identity "ghost"/,
                 fn ->
                   Config.load_map!(configured, path: ctx.path)
                 end
  end

  test "the private key must be an ${env:VAR} reference that is set", ctx do
    literal = put_in(fixture(), ["identities", "ana-bot", "private_key"], @key)

    assert_raise Error, ~r/private_key must be an \$\{env:VAR\} reference/, fn ->
      Config.load_map!(literal, path: ctx.path)
    end

    System.delete_env(@env_var)

    assert_raise Error, ~r/references environment variable #{@env_var}, which is unset/, fn ->
      Config.load_map!(fixture(), path: ctx.path)
    end
  end

  test "rejects an unknown kind, unknown field, or missing id", ctx do
    invalid = %{
      ~r/kind must be one of github-app/ =>
        put_in(fixture(), ["identities", "ana-bot", "kind"], "jira"),
      ~r/unknown fields \["webhook_secret"\]/ =>
        put_in(fixture(), ["identities", "ana-bot", "webhook_secret"], "x"),
      ~r/missing required field "installation_id"/ =>
        pop_in(fixture(), ["identities", "ana-bot", "installation_id"]) |> elem(1),
      ~r/name must be kebab-case/ =>
        put_in(fixture(), ["identities", "Ana Bot"], fixture()["identities"]["ana-bot"])
    }

    for {message, configured} <- invalid do
      assert_raise Error, message, fn -> Config.load_map!(configured, path: ctx.path) end
    end
  end

  test "integer ids are accepted and stored as strings", ctx do
    configured = put_in(fixture(), ["identities", "ana-bot", "app_id"], 123_456)

    assert :ok = Config.load_map!(configured, path: ctx.path)
    assert %Identity{app_id: "123456"} = Config.get_identity("ana-bot")
  end

  test "identities may be split into an include piece", ctx do
    File.mkdir_p!(Path.join(ctx.root, "identities"))

    File.write!(Path.join(ctx.root, "identities/ana-bot.toml"), """
    [identities.ana-bot]
    kind = "github-app"
    app_id = "123456"
    installation_id = "987654"
    private_key = "${env:#{@env_var}}"
    """)

    File.write!(ctx.path, """
    include = ["identities"]

    [limits]
    max_concurrent_containers = 4

    [repositories.app]
    path = "repo"
    base_branch = "main"

    [runtimes.docker.runc.debian.images]
    opencode = "omashiki/agent:latest"

    [presets.reviewer]
    plugin = "opencode"
    identities = ["ana-bot"]

    [environments.review]
    runtime = "docker.runc.debian"
    sink = "git"
    packages = []
    preset = "reviewer"
    executables = ["git"]
    credentials = []
    caches = []
    timeout_ms = 1800000
    network = "restricted"
    mounts = []
    pre_steps = []
    post_steps = []

    [environments.review.policy]
    mode = "off"

    [environments.review.resources]
    cpus = 2.0
    memory = "2GB"
    pids = 256
    """)

    assert :ok = Config.load!(ctx.path)
    assert [%Identity{name: "ana-bot"}] = Config.identities()
    assert [%Preset{identities: [%{name: "ana-bot"}]}] = Config.presets()
  end

  defp fixture do
    %{
      "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
      "identities" => %{
        "ana-bot" => %{
          "kind" => "github-app",
          "app_id" => "123456",
          "installation_id" => "987654",
          "private_key" => "${env:#{@env_var}}"
        }
      },
      "presets" => %{
        "reviewer" => %{"plugin" => "opencode", "identities" => ["ana-bot"]}
      },
      "runtimes" => %{
        "docker" => %{
          "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
        }
      },
      "environments" => %{
        "review" => %{
          "runtime" => "docker.runc.debian",
          "sink" => "git",
          "packages" => [],
          "preset" => "reviewer",
          "executables" => ["git"],
          "credentials" => [],
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
