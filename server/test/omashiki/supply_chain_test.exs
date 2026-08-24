defmodule Omashiki.SupplyChainTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.Error
  alias Omashiki.Runtimes.CacheGroup
  alias Omashiki.SupplyChain.{Manifest, Policy}
  alias Omashiki.SupplyChain.Preflight

  @git_commit String.duplicate("a", 40)
  @sha256 String.duplicate("b", 64)

  setup do
    Config.reset!()
    on_exit(fn -> Config.reset!() end)
    :ok
  end

  test "normalizes registries, package constraints, immutable sources, and roots" do
    root = tmp_dir!()

    assert {:ok, policy} =
             Policy.parse(%{
               "mode" => "allowlist",
               "registries" => %{
                 "npm" => %{
                   "public" => %{"url" => "https://registry.npmjs.org/"},
                   "private" => %{
                     "url" => "https://npm.example.test/",
                     "credential_env" => "NPM_TOKEN"
                   }
                 },
                 "cargo" => %{
                   "public" => %{"url" => "https://index.crates.io/"},
                   "private" => %{
                     "url" => "https://cargo.example.test",
                     "credential_env" => "CARGO_TOKEN"
                   }
                 },
                 "go" => %{
                   "public" => %{"url" => "https://proxy.golang.org"},
                   "private" => %{
                     "url" => "https://go.example.test",
                     "credential_env" => "GOPROXY_TOKEN"
                   }
                 }
               },
               "packages" => %{
                 "npm" => %{"left-pad" => "1.3.*"},
                 "cargo" => %{"serde" => "1.0.200"},
                 "go" => %{"example.com/acme" => "v1.2.3"}
               },
               "git" => [%{"url" => "https://github.com/acme/tool", "commit" => @git_commit}],
               "direct_urls" => [
                 %{"url" => "https://downloads.example.test/tool.tgz", "sha256" => @sha256}
               ],
               "local_roots" => [root]
             })

    assert policy.mode == :allowlist
    assert policy.registries["npm"]["private"].credential_env == "NPM_TOKEN"
    assert policy.registries["npm"]["public"].url == "https://registry.npmjs.org"
    assert policy.packages["cargo"]["serde"] == "1.0.200"
    assert hd(policy.git).commit == @git_commit
    assert hd(policy.direct_urls).sha256 == @sha256
    assert policy.local_roots == [root]
  end

  test "matches exact and trailing wildcard versions only" do
    assert Policy.version_allowed?("1.2.3", "1.2.3")
    assert Policy.version_allowed?("1.2.99", "1.2.*")
    refute Policy.version_allowed?("1.3.0", "1.2.*")
    refute Policy.version_allowed?("1.20.0", "1.2.*")
    refute Policy.version_allowed?("1.2.3", ">=1.2,<2")

    assert {:error, message} =
             Policy.parse(%{"mode" => "allowlist", "packages" => %{"npm" => %{"x" => ">=1"}}})

    assert message =~ "only exact versions and trailing .* wildcards"
  end

  test "rejects unknown modes, ecosystems, insecure or credential-bearing URLs" do
    invalid = [
      {%{"mode" => "enforce"}, ~r/unknown mode/},
      {%{"mode" => "allowlist", "packages" => %{"python" => %{"x" => "1.0.0"}}},
       ~r/unknown ecosystem/},
      {%{
         "mode" => "allowlist",
         "registries" => %{"npm" => %{"public" => %{"url" => "http://registry.test"}}}
       }, ~r/must use https/},
      {%{
         "mode" => "allowlist",
         "registries" => %{"npm" => %{"public" => %{"url" => "https://user:pass@registry.test"}}}
       }, ~r/credentials/},
      {%{
         "mode" => "allowlist",
         "registries" => %{"npm" => %{"public" => %{"url" => "https://[bad"}}}
       }, ~r/malformed/},
      {%{
         "mode" => "allowlist",
         "registries" => %{
           "npm" => %{
             "private" => %{"url" => "https://registry.test", "credential_env" => "token"}
           }
         }
       }, ~r/environment variable name/},
      {%{"mode" => "off", "packages" => %{"npm" => %{"x" => "1.0.0"}}},
       ~r/conflicts with non-empty/}
    ]

    Enum.each(invalid, fn {attrs, message} ->
      assert {:error, reason} = Policy.parse(attrs)
      assert reason =~ message
    end)
  end

  test "rejects conflicting registry/source declarations and mutable pins" do
    assert {:error, message} =
             Policy.parse(%{
               "mode" => "allowlist",
               "registries" => %{
                 "npm" => %{
                   "public" => %{"url" => "https://registry.test"},
                   "private" => %{"url" => "https://registry.test", "credential_env" => "TOKEN"}
                 }
               }
             })

    assert message =~ "URLs conflict"

    assert {:error, message} =
             Policy.parse(%{
               "mode" => "allowlist",
               "git" => [%{"url" => "https://github.com/a/b", "commit" => "deadbeef"}]
             })

    assert message =~ "full 40-character"

    assert {:error, message} =
             Policy.parse(%{
               "mode" => "allowlist",
               "direct_urls" => [%{"url" => "https://example.test/a", "sha256" => "1234"}]
             })

    assert message =~ "64-character SHA-256"
  end

  test "Config preserves absent policy as nil and parses an explicit policy" do
    cache = %{"host" => "~/.cache/omashiki/policy-test"}
    assert :ok = Config.load_map!(%{"caches" => %{"plain" => cache}})
    assert %CacheGroup{policy: nil} = Config.get_cache("plain")

    cache =
      Map.put(cache, "policy", %{
        "mode" => "audit",
        "registries" => %{"npm" => %{"public" => %{"url" => "https://registry.npmjs.org"}}}
      })

    assert :ok = Config.load_map!(%{"caches" => %{"audited" => cache}})
    assert %CacheGroup{policy: %Policy{mode: :audit}} = Config.get_cache("audited")
  end

  test "Config turns malformed policy into Config.Error" do
    assert_raise Error, ~r/unknown mode/, fn ->
      Config.load_map!(%{
        "caches" => %{
          "bad" => %{"host" => "~/.cache/omashiki/policy-test", "policy" => %{"mode" => "wat"}}
        }
      })
    end
  end

  test "Manifest inspects package lock, Cargo, and Go sources" do
    root = tmp_dir!()

    write!(root, "package.json", Jason.encode!(%{"dependencies" => %{"left-pad" => "^1.3.0"}}))

    write!(
      root,
      "package-lock.json",
      Jason.encode!(%{
        "packages" => %{
          "" => %{},
          "node_modules/left-pad" => %{
            "version" => "1.3.0",
            "resolved" => "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz"
          }
        }
      })
    )

    write!(root, "Cargo.toml", "[dependencies]\nserde = \"1.0.200\"\n")

    write!(
      root,
      "Cargo.lock",
      "[[package]]\nname = \"serde\"\nversion = \"1.0.200\"\nsource = \"registry+https://index.crates.io/\"\n"
    )

    write!(root, "go.mod", "module example.test/app\n\nrequire example.com/acme v1.2.3\n")
    write!(root, "go.sum", "example.com/acme v1.2.3 h1:abc\n")

    assert {:ok, manifest} = Manifest.inspect(root)

    assert Enum.sort(manifest.files) == [
             "Cargo.lock",
             "Cargo.toml",
             "go.mod",
             "go.sum",
             "package-lock.json",
             "package.json"
           ]

    assert Enum.any?(
             manifest.dependencies,
             &(&1.name == "left-pad" and &1.version == "1.3.0" and &1.source == :registry)
           )

    assert Enum.any?(
             manifest.dependencies,
             &(&1.name == "serde" and &1.source == :registry and &1.locked)
           )

    assert Enum.any?(
             manifest.dependencies,
             &(&1.name == "example.com/acme" and &1.version == "v1.2.3")
           )

    legacy = tmp_dir!()
    write!(legacy, "package.json", Jason.encode!(%{"dependencies" => %{"legacy" => "^2.0.0"}}))

    write!(
      legacy,
      "package-lock.json",
      Jason.encode!(%{"dependencies" => %{"legacy" => %{"version" => "2.0.1"}}})
    )

    write!(
      legacy,
      "go.mod",
      "module example.test/app\n\nrequire example.com/local v1.0.0\nreplace example.com/local => ../local\n"
    )

    assert {:ok, legacy_manifest} = Manifest.inspect(legacy)

    assert Enum.any?(
             legacy_manifest.dependencies,
             &(&1.name == "legacy" and &1.version == "2.0.1" and &1.locked)
           )

    assert Enum.any?(
             legacy_manifest.dependencies,
             &(&1.name == "example.com/local" and &1.source == :local)
           )
  end

  test "preflight allows pinned dependencies, reports audit violations, and blocks allowlist violations" do
    root = tmp_dir!()
    write!(root, "package.json", Jason.encode!(%{"dependencies" => %{"left-pad" => "1.3.0"}}))

    policy =
      Policy.parse!(%{
        "mode" => "allowlist",
        "registries" => %{"npm" => %{"public" => %{"url" => "https://registry.npmjs.org"}}},
        "packages" => %{"npm" => %{"left-pad" => "1.3.0"}}
      })

    assert {:ok, %{violations: []}} = Preflight.run(root, policy)

    audit = %{policy | mode: :audit}

    assert {:ok, %{violations: violations}} =
             Preflight.run(root, %{audit | packages: %{"npm" => %{"other" => "1.0.0"}}})

    assert [%{reason: reason}] = violations
    assert reason =~ "not allowlisted"

    assert {:error, %{violations: [_]}} = Preflight.run(root, %{policy | packages: %{}})
  end

  test "Git and direct URL decisions require both immutable parts" do
    policy =
      Policy.parse!(%{
        "mode" => "allowlist",
        "git" => [%{"url" => "https://github.com/acme/tool", "commit" => @git_commit}],
        "direct_urls" => [
          %{"url" => "https://downloads.example.test/tool.tgz", "sha256" => @sha256}
        ]
      })

    assert {:allow, _} =
             Policy.authorize(policy, %{
               ecosystem: "cargo",
               name: "tool",
               source: :git,
               source_url: "https://github.com/acme/tool",
               commit: @git_commit
             })

    assert {:deny, _} =
             Policy.authorize(policy, %{
               ecosystem: "cargo",
               name: "tool",
               source: :git,
               source_url: "https://github.com/acme/tool",
               commit: String.duplicate("c", 40)
             })

    assert {:allow, _} =
             Policy.authorize(policy, %{
               ecosystem: "npm",
               name: "tool",
               source: :direct_url,
               source_url: "https://downloads.example.test/tool.tgz",
               sha256: @sha256
             })

    assert {:deny, _} =
             Policy.authorize(policy, %{
               ecosystem: "npm",
               name: "tool",
               source: :direct_url,
               source_url: "https://downloads.example.test/tool.tgz"
             })
  end

  test "local preflight rejects traversal and symlink escapes" do
    root = tmp_dir!()
    outside = tmp_dir!()
    local = Path.join(root, "local")
    File.mkdir_p!(local)
    write!(local, "package.json", "{}")
    File.ln_s!(outside, Path.join(root, "escape"))

    assert Preflight.local_source_allowed?(local, [root])
    refute Preflight.local_source_allowed?(Path.join(root, "escape"), [root])
    refute Preflight.local_source_allowed?(Path.join(root, ".."), [root])
  end

  test "allowlist preflight rejects remote Git even when pinned until it can be mediated" do
    root = tmp_dir!()

    write!(
      root,
      "package.json",
      Jason.encode!(%{
        "dependencies" => %{
          "tool" => "git+https://github.com/acme/tool##{@git_commit}"
        }
      })
    )

    policy =
      Policy.parse!(%{
        "mode" => "allowlist",
        "git" => [%{"url" => "https://github.com/acme/tool", "commit" => @git_commit}]
      })

    assert {:error, %{violations: [violation]}} = Preflight.run(root, policy)
    assert violation.reason =~ "not mediated in allowlist mode"

    assert {:ok, %{violations: []}} = Preflight.run(root, %{policy | mode: :audit})
  end

  test "local dependency must be inside both the policy root and a mounted root" do
    root = tmp_dir!()
    project = Path.join(root, "project")
    local = Path.join(root, "local")
    File.mkdir_p!(project)
    File.mkdir_p!(local)

    write!(
      project,
      "package.json",
      Jason.encode!(%{"dependencies" => %{"local-package" => "file:../local"}})
    )

    policy = Policy.parse!(%{"mode" => "allowlist", "local_roots" => [root]})

    assert {:ok, %{violations: []}} =
             Preflight.run(project, policy, mounted_roots: [root])

    assert {:error, %{violations: [violation]}} =
             Preflight.run(project, policy, mounted_roots: [project])

    assert violation.reason =~ "not mounted into the agent"
  end

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "omashiki-supply-chain-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write!(root, name, contents) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
