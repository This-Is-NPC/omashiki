defmodule Omashiki.Config.RegistryTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.{Environment, Error, Node, Repository, ResolvedJob, Step}
  alias Omashiki.Credentials.Credential

  setup do
    Config.reset!()
    root = Path.join(System.tmp_dir!(), "omashiki-registry-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    mount = Path.join(root, "operator.json")
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    File.write!(mount, "{}")

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, repo: repo, mount: mount}
  end

  test "loads a complete repository and environment registry", ctx do
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))

    assert [%Repository{name: "app", path: path, base_branch: "main", remote: nil}] =
             Config.repositories()

    assert path == ctx.repo

    assert [
             %Environment{
               name: "opencode",
               harness: "opencode",
               harness_profile: %{name: "opencode"},
               executables: ["mise", "git"],
               credentials: [%Credential{name: "provider"}],
               timeout_ms: 1_800_000,
               network: "restricted",
               pre_steps: [%Step{argv: ["mise", "install", "--yes"], condition: "always"}],
               post_steps: [%Step{condition: "on_success"}],
               resources: %{nano_cpus: 2_000_000_000, memory_bytes: 2_147_483_648}
             }
           ] = Config.environments()

    assert {:ok, %ResolvedJob{} = resolved} = Config.resolve_job("app", "opencode")
    assert resolved.repository.path == ctx.repo
    assert resolved.environment.name == "opencode"
    assert resolved.environment.harness_profile.adapter == Omashiki.Harness.OpenCode
    assert resolved.environment.harness_profile.launch_plan.transport["kind"] == "http"
    assert resolved.digest == Config.current_digest()
    refute resolved.digest =~ "secret-value"
  end

  test "validates harness adapter options at load and changes the registry digest", ctx do
    invalid = put_in(fixture(ctx), ["harnesses", "opencode", "options"], %{"unknown" => true})

    assert_raise Error, ~r/unknown_options/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end

    Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    first = Config.current_digest()
    changed = put_in(fixture(ctx), ["harnesses", "opencode", "options", "internal_port"], 4097)
    Config.load_map!(changed, path: Path.join(ctx.root, "omashiki.toml"))
    refute Config.current_digest() == first
  end

  test "a reload cannot mutate an admitted job snapshot", ctx do
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    assert {:ok, captured} = Config.resolve_job("app", "opencode")

    reloaded = put_in(fixture(ctx), ["repositories", "app", "base_branch"], "next")
    assert :ok = Config.load_map!(reloaded, path: Path.join(ctx.root, "omashiki.toml"))

    assert captured.repository.base_branch == "main"
    assert captured.digest != Config.current_digest()
    assert {:ok, current} = Config.resolve_job("app", "opencode")
    assert current.repository.base_branch == "next"
  end

  test "digest is deterministic and excludes credential secrets", ctx do
    first = fixture(ctx)
    assert :ok = Config.load_map!(first, path: Path.join(ctx.root, "omashiki.toml"))
    digest = Config.current_digest()

    assert :ok =
             first
             |> put_in(["credentials", "provider", "api_key"], "rotated-secret")
             |> Config.load_map!(path: Path.join(ctx.root, "omashiki.toml"))

    assert Config.current_digest() == digest
  end

  test "snapshot and digest include the reachable credential fallback graph", ctx do
    configured =
      fixture(ctx)
      |> put_in(["credentials", "provider", "fallback_chain"], ["backup"])
      |> put_in(
        ["credentials", "backup"],
        %{"provider" => "openai_compat", "model" => "backup-model", "api_key" => "backup-key"}
      )

    Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))

    assert [%Credential{name: "provider"}, %Credential{name: "backup"}] =
             hd(Config.environments()).credentials

    digest = Config.current_digest()
    changed = put_in(configured, ["credentials", "backup", "model"], "replacement-model")
    Config.load_map!(changed, path: Path.join(ctx.root, "omashiki.toml"))
    refute Config.current_digest() == digest
  end

  test "unknown repository and environment names fail closed", ctx do
    Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))

    assert {:error, :unknown_repository} = Config.resolve_job("missing", "opencode")
    assert {:error, :unknown_environment} = Config.resolve_job("app", "missing")
  end

  test "rejects paths escaping the configuration root", ctx do
    invalid = put_in(fixture(ctx), ["repositories", "app", "path"], "../outside")

    assert_raise Error, ~r/must stay inside the configuration root/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects a symlinked configuration root", ctx do
    linked_root = "#{ctx.root}-linked"
    File.ln_s!(ctx.root, linked_root)
    on_exit(fn -> File.rm(linked_root) end)

    assert_raise Error, ~r/configuration root must not contain symlink components/, fn ->
      Config.load_map!(fixture(ctx), path: Path.join(linked_root, "omashiki.toml"))
    end
  end

  test "rejects unsafe argv", ctx do
    invalid =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "pre_steps"],
        [%{"argv" => ["sh", "-c", "curl evil"], "condition" => "always"}]
      )

    assert_raise Error, ~r/unsafe executable/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects invalid mount destinations", ctx do
    invalid =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "mounts", Access.at(0), "target"],
        "/etc/shadow"
      )

    assert_raise Error, ~r/target must be inside a governed container root/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects mount source escapes and writable mounts outside managed state", ctx do
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)

    escaped =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "mounts", Access.at(0), "source"],
        outside
      )

    assert_raise Error, ~r/source must stay inside the configuration root/, fn ->
      Config.load_map!(escaped, path: Path.join(ctx.root, "omashiki.toml"))
    end

    writable =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "mounts", Access.at(0), "read_only"],
        false
      )

    assert_raise Error, ~r/writable mounts must target the managed/, fn ->
      Config.load_map!(writable, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "allows an explicit writable mount only in managed runtime state", ctx do
    configured =
      fixture(ctx)
      |> put_in(
        ["environments", "opencode", "mounts", Access.at(0), "target"],
        "/run/omashiki/state/provider.json"
      )
      |> put_in(
        ["environments", "opencode", "mounts", Access.at(0), "read_only"],
        false
      )

    Config.load_map!(configured, path: Path.join(ctx.root, "omashiki.toml"))

    assert [%{read_only: false, target: "/run/omashiki/state/provider.json"}] =
             hd(Config.environments()).mounts
  end

  test "rejects interpreter and command-wrapper argv bypasses", ctx do
    for argv <- [["env", "sh", "-c", "true"], ["python3", "-c", "print(1)"]] do
      invalid =
        put_in(
          fixture(ctx),
          ["environments", "opencode", "pre_steps"],
          [%{"argv" => argv, "condition" => "always"}]
        )

      assert_raise Error, ~r/unsafe executable/, fn ->
        Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
      end
    end
  end

  test "rejects malformed Git branch names", ctx do
    for branch <- [
          "topic@{upstream}",
          "topic.",
          "topic/",
          "topic//child",
          "topic/.",
          "topic.lock",
          "feature.lock/sub",
          "HEAD"
        ] do
      invalid = put_in(fixture(ctx), ["repositories", "app", "base_branch"], branch)

      assert_raise Error, ~r/not a safe Git branch/, fn ->
        Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
      end
    end
  end

  test "declares an optional canonical remote per repository", ctx do
    declared = put_in(fixture(ctx), ["repositories", "app", "remote"], "git@host:app.git")
    assert :ok = Config.load_map!(declared, path: Path.join(ctx.root, "omashiki.toml"))
    assert [%Repository{remote: "git@host:app.git"}] = Config.repositories()
    assert {:ok, resolved} = Config.resolve_job("app", "opencode")
    assert resolved.repository.remote == "git@host:app.git"
  end

  test "rejects unsafe canonical remotes", ctx do
    for remote <- ["ext::sh -c whoami", "--upload-pack=rm -rf /", "git@host:a b.git", ""] do
      invalid = put_in(fixture(ctx), ["repositories", "app", "remote"], remote)

      assert_raise Error, ~r/remote/, fn ->
        Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
      end
    end
  end

  test "declares execution nodes", ctx do
    put_env!("OMASHIKI_NODE", "builder-01")
    declared = Map.put(fixture(ctx), "nodes", %{"builder-02" => %{}, "builder-01" => %{}})
    assert :ok = Config.load_map!(declared, path: Path.join(ctx.root, "omashiki.toml"))

    assert [%Node{name: "builder-01"}, %Node{name: "builder-02"}] = Config.nodes()
    assert Config.current_node() == %Node{name: "builder-01"}
  end

  test "rejects unknown node fields and malformed node names", ctx do
    unknown = Map.put(fixture(ctx), "nodes", %{"builder-01" => %{"docker_socket" => "/x.sock"}})

    assert_raise Error, ~r/nodes\.builder-01: unknown fields \["docker_socket"\]/, fn ->
      Config.load_map!(unknown, path: Path.join(ctx.root, "omashiki.toml"))
    end

    for name <- ["Builder-01", "builder_01", "builder--01", "-builder", ""] do
      invalid = Map.put(fixture(ctx), "nodes", %{name => %{}})

      assert_raise Error, ~r/name must be kebab-case/, fn ->
        Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
      end
    end

    not_a_table = Map.put(fixture(ctx), "nodes", %{"builder-01" => "socket"})

    assert_raise Error, ~r/nodes\.builder-01 must be a table/, fn ->
      Config.load_map!(not_a_table, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  # The compatibility contract. Everything below the config layer — the claim
  # path, recovery, the operator UI — reads `current_node/0`, so an absent
  # section must still answer, and must answer with exactly one node.
  test "no [nodes] section yields exactly one implicit local node", ctx do
    put_env!("OMASHIKI_NODE", "implicit-host")
    refute Map.has_key?(fixture(ctx), "nodes")
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))

    assert [%Node{name: "implicit-host"}] = Config.nodes()
    assert Config.current_node() == %Node{name: "implicit-host"}
  end

  test "the implicit local node falls back to the hostname", ctx do
    put_env!("OMASHIKI_NODE", nil)
    {:ok, host} = :inet.gethostname()
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))

    assert [%Node{name: name}] = Config.nodes()
    assert name == List.to_string(host)
  end

  # One declared node is how an operator names this machine, so it is this
  # machine whatever the hostname says. More than one is a cluster, and a host
  # in none of them would claim work under a node id no other machine, and no
  # per-node capacity row, has ever heard of.
  test "a single declared node is this machine regardless of hostname", ctx do
    put_env!("OMASHIKI_NODE", nil)
    declared = Map.put(fixture(ctx), "nodes", %{"solo" => %{}})
    assert :ok = Config.load_map!(declared, path: Path.join(ctx.root, "omashiki.toml"))
    assert Config.current_node() == %Node{name: "solo"}
  end

  test "rejects a machine that is absent from the declared node list", ctx do
    put_env!("OMASHIKI_NODE", "ghost")
    declared = Map.put(fixture(ctx), "nodes", %{"builder-01" => %{}, "builder-02" => %{}})

    assert_raise Error, ~r/"ghost", which is not declared in \[nodes\]/, fn ->
      Config.load_map!(declared, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  # Adding or draining a machine is a deployment, not configuration drift. If
  # the node list were hashed, every in-flight job's admitted digest would go
  # stale on a routine scale-out.
  test "the registry digest ignores the node list", ctx do
    put_env!("OMASHIKI_NODE", "builder-01")
    assert :ok = Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    without_nodes = Config.current_digest()

    declared = Map.put(fixture(ctx), "nodes", %{"builder-01" => %{}, "builder-02" => %{}})
    assert :ok = Config.load_map!(declared, path: Path.join(ctx.root, "omashiki.toml"))

    assert Config.current_digest() == without_nodes
    assert length(Config.nodes()) == 2
  end

  test "rejects policy rules when policy mode is off", ctx do
    invalid =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "policy"],
        %{"mode" => "off", "local_roots" => [ctx.repo]}
      )

    assert_raise Error, ~r/mode off cannot declare policy rules/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects undeclared step executables and duplicate bindings", ctx do
    undeclared =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "pre_steps"],
        [%{"argv" => ["cargo", "build"], "condition" => "always"}]
      )

    assert_raise Error, ~r/executable "cargo" is not declared/, fn ->
      Config.load_map!(undeclared, path: Path.join(ctx.root, "omashiki.toml"))
    end

    duplicates =
      put_in(
        fixture(ctx),
        ["environments", "opencode", "credentials"],
        ["provider", "provider"]
      )

    assert_raise Error, ~r/must not contain duplicate names/, fn ->
      Config.load_map!(duplicates, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects malformed credentials and unbounded resources", ctx do
    malformed_credential =
      put_in(fixture(ctx), ["credentials", "provider", "provider"], 123)

    assert_raise Error, ~r/provider must be a non-empty string/, fn ->
      Config.load_map!(malformed_credential, path: Path.join(ctx.root, "omashiki.toml"))
    end

    embedded_secret =
      put_in(
        fixture(ctx),
        ["credentials", "provider", "base_url"],
        "https://operator:secret@example.test/v1"
      )

    assert_raise Error, ~r/base_url must be an HTTP URL without embedded credentials/, fn ->
      Config.load_map!(embedded_secret, path: Path.join(ctx.root, "omashiki.toml"))
    end

    query_secret =
      put_in(
        fixture(ctx),
        ["credentials", "provider", "base_url"],
        "https://example.test/v1?api_key=secret"
      )

    assert_raise Error, ~r/without embedded credentials, query, or fragment/, fn ->
      Config.load_map!(query_secret, path: Path.join(ctx.root, "omashiki.toml"))
    end

    excessive_cpu = put_in(fixture(ctx), ["environments", "opencode", "resources", "cpus"], 65)

    assert_raise Error, ~r/cpus must be between 1 and 64/, fn ->
      Config.load_map!(excessive_cpu, path: Path.join(ctx.root, "omashiki.toml"))
    end

    sub_nanocore =
      put_in(fixture(ctx), ["environments", "opencode", "resources", "cpus"], 1.0e-10)

    assert_raise Error, ~r/must resolve to at least one nano-CPU/, fn ->
      Config.load_map!(sub_nanocore, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "resolves an api_key declared as an environment reference", ctx do
    var = "OMASHIKI_TEST_API_KEY_#{System.unique_integer([:positive])}"
    referenced = put_in(fixture(ctx), ["credentials", "provider", "api_key"], "${env:#{var}}")

    on_exit(fn -> System.delete_env(var) end)

    assert_raise Error, ~r/references environment variable #{var}, which is unset or empty/, fn ->
      Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    end

    System.put_env(var, "")

    assert_raise Error, ~r/references environment variable #{var}, which is unset or empty/, fn ->
      Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    end

    System.put_env(var, "resolved-secret")

    assert :ok = Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    assert %Credential{api_key: "resolved-secret"} = Config.get_credential("provider")
  end

  test "leaves an api_key that is not an environment reference verbatim", ctx do
    literal =
      put_in(fixture(ctx), ["credentials", "provider", "api_key"], "${env:not a var name}")

    assert :ok = Config.load_map!(literal, path: Path.join(ctx.root, "omashiki.toml"))
    assert %Credential{api_key: "${env:not a var name}"} = Config.get_credential("provider")
  end

  test "resolves a base_url declared as an environment reference", ctx do
    var = "OMASHIKI_TEST_BASE_URL_#{System.unique_integer([:positive])}"
    referenced = put_in(fixture(ctx), ["credentials", "provider", "base_url"], "${env:#{var}}")

    on_exit(fn -> System.delete_env(var) end)

    assert_raise Error, ~r/references environment variable #{var}, which is unset or empty/, fn ->
      Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    end

    System.put_env(var, "")

    assert_raise Error, ~r/references environment variable #{var}, which is unset or empty/, fn ->
      Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    end

    System.put_env(var, "http://192.0.2.10:8080/v1")

    assert :ok = Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    assert %Credential{base_url: "http://192.0.2.10:8080/v1"} = Config.get_credential("provider")
  end

  test "validates the resolved base_url, not the reference", ctx do
    var = "OMASHIKI_TEST_BASE_URL_#{System.unique_integer([:positive])}"
    referenced = put_in(fixture(ctx), ["credentials", "provider", "base_url"], "${env:#{var}}")

    on_exit(fn -> System.delete_env(var) end)
    System.put_env(var, "https://operator:secret@example.test/v1")

    assert_raise Error, ~r/base_url must be an HTTP URL without embedded credentials/, fn ->
      Config.load_map!(referenced, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "leaves a base_url that is not an environment reference verbatim", ctx do
    literal =
      put_in(
        fixture(ctx),
        ["credentials", "provider", "base_url"],
        "http://example.test/${env:X}"
      )

    assert :ok = Config.load_map!(literal, path: Path.join(ctx.root, "omashiki.toml"))

    assert %Credential{base_url: "http://example.test/${env:X}"} =
             Config.get_credential("provider")
  end

  test "rejects symlinked Git metadata", ctx do
    File.rm_rf!(Path.join(ctx.repo, ".git"))
    external_git = Path.join(ctx.root, "external.git")
    File.mkdir_p!(external_git)
    File.ln_s!(external_git, Path.join(ctx.repo, ".git"))

    assert_raise Error, ~r/non-symlink Git repository/, fn ->
      Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects symlinked Git object directories", ctx do
    objects = Path.join([ctx.repo, ".git", "objects"])
    external_objects = Path.join(ctx.root, "external-objects")
    File.rm_rf!(objects)
    File.mkdir_p!(external_objects)
    File.ln_s!(external_objects, objects)

    assert_raise Error, ~r/non-symlink Git repository/, fn ->
      Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects external Git pointer metadata without a worktree backlink", ctx do
    File.rm_rf!(Path.join(ctx.repo, ".git"))

    external_git =
      Path.join(System.tmp_dir!(), "external-gitdir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(external_git)
    File.write!(Path.join(ctx.repo, ".git"), "gitdir: #{external_git}\n")
    on_exit(fn -> File.rm_rf!(external_git) end)

    assert_raise Error, ~r/non-symlink Git repository/, fn ->
      Config.load_map!(fixture(ctx), path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects unknown and cyclic credential fallback chains", ctx do
    unknown =
      put_in(fixture(ctx), ["credentials", "provider", "fallback_chain"], ["missing"])

    assert_raise Error, ~r/unknown credential "missing"/, fn ->
      Config.load_map!(unknown, path: Path.join(ctx.root, "omashiki.toml"))
    end

    cyclic =
      fixture(ctx)
      |> put_in(["credentials", "provider", "fallback_chain"], ["backup"])
      |> put_in(
        ["credentials", "backup"],
        %{
          "provider" => "openai_compat",
          "model" => "backup-model",
          "fallback_chain" => ["provider"]
        }
      )

    assert_raise Error, ~r/fallback_chain contains a cycle/, fn ->
      Config.load_map!(cyclic, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects cache paths with symlink components", ctx do
    cache_root = Path.join(ctx.root, "cache-root")
    real_cache = Path.join(cache_root, "real")
    linked_cache = Path.join(cache_root, "linked")
    File.mkdir_p!(real_cache)
    File.ln_s!(real_cache, linked_cache)

    previous_cache_root = System.get_env("OMASHIKI_CACHE_ROOT")
    System.put_env("OMASHIKI_CACHE_ROOT", cache_root)

    on_exit(fn ->
      if previous_cache_root,
        do: System.put_env("OMASHIKI_CACHE_ROOT", previous_cache_root),
        else: System.delete_env("OMASHIKI_CACHE_ROOT")
    end)

    invalid = put_in(fixture(ctx), ["caches", "global", "host"], linked_cache)

    assert_raise Error, ~r/host must not contain symlink components/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "rejects non-string cache paths with a config error", ctx do
    invalid = put_in(fixture(ctx), ["caches", "global", "host"], 123)

    assert_raise Error, ~r/host must be a string path/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  test "requires explicit CPU and memory resource limits", ctx do
    for key <- ["cpus", "memory"] do
      invalid =
        update_in(fixture(ctx), ["environments", "opencode", "resources"], &Map.delete(&1, key))

      assert_raise Error, fn ->
        Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
      end
    end
  end

  test "rejects allowlist policy without restricted networking", ctx do
    invalid = put_in(fixture(ctx), ["environments", "opencode", "network"], "host")

    assert_raise Error, ~r/allowlist policy requires restricted network/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  defp put_env!(name, nil) do
    previous = System.get_env(name)
    System.delete_env(name)
    on_exit(fn -> restore_env(name, previous) end)
  end

  defp put_env!(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_env(name, previous) end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, previous), do: System.put_env(name, previous)

  defp fixture(ctx) do
    %{
      "repositories" => %{
        "app" => %{"path" => "repo", "base_branch" => "main"}
      },
      "harnesses" => %{
        "opencode" => %{
          "adapter" => "opencode",
          "runtime" => "docker",
          "image" => "omashiki/agent:latest",
          "options" => %{}
        }
      },
      "credentials" => %{
        "provider" => %{
          "provider" => "openai_compat",
          "model" => "model",
          "api_key" => "secret-value"
        }
      },
      "caches" => %{
        "global" => %{"host" => "~/.cache/omashiki/registry-test"}
      },
      "environments" => %{
        "opencode" => %{
          "harness" => "opencode",
          "executables" => ["mise", "git"],
          "credentials" => ["provider"],
          "timeout_ms" => 1_800_000,
          "caches" => ["global"],
          "mounts" => [
            %{
              "source" => ctx.mount,
              "target" => "/run/omashiki/operator.json",
              "read_only" => true
            }
          ],
          "pre_steps" => [
            %{
              "argv" => ["mise", "install", "--yes"],
              "condition" => "always",
              "timeout_ms" => 600_000
            }
          ],
          "post_steps" => [
            %{"argv" => ["git", "status", "--porcelain"], "condition" => "on_success"}
          ],
          "policy" => %{"mode" => "allowlist"},
          "network" => "restricted",
          "resources" => %{"cpus" => 2.0, "memory" => "2GB", "pids" => 256}
        }
      }
    }
  end
end
