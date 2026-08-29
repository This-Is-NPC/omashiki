defmodule Omashiki.Runtimes.RuntimeTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.Error
  alias Omashiki.Runtime.Spec

  setup do
    Config.reset!()

    root =
      Path.join(System.tmp_dir!(), "omashiki-runtime-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    mount = Path.join(root, "operator.json")
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    File.write!(mount, "{}")

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, mount: mount}
  end

  test "runtime specs expose the catalog identity and selected image" do
    spec = %Spec{
      name: "docker.runc.debian",
      backend: "docker",
      handler: "runc",
      distribution: "debian",
      plugin: "opencode",
      image: "agent"
    }

    assert Omashiki.Runtimes.image(spec) == "agent"
  end

  test "rejects runtime= on presets at config load", ctx do
    invalid =
      fixture(ctx)
      |> put_in(["presets", "opencode", "runtime"], "kata")

    assert_raise Error, ~r/unknown field "runtime"/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

  defp fixture(ctx) do
    %{
      "repositories" => %{
        "app" => %{"path" => "repo", "base_branch" => "main"}
      },
      "presets" => %{
        "opencode" => %{"plugin" => "opencode", "options" => %{}}
      },
      "runtimes" => %{
        "docker" => %{
          "runc" => %{
            "debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}
          }
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
        "global" => %{"host" => "~/.cache/omashiki/runtime-test"}
      },
      "environments" => %{
        "opencode" => %{
          "runtime" => "docker.runc.debian",
          "sink" => "git",
          "packages" => [],
          "preset" => "opencode",
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
          "policy" => %{"mode" => "allowlist"},
          "network" => "restricted",
          "resources" => %{"cpus" => 2.0, "memory" => "2GB", "pids" => 256}
        }
      }
    }
  end
end
