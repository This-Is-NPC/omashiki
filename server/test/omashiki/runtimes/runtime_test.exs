defmodule Omashiki.Runtimes.RuntimeTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.Error
  alias Omashiki.Runtimes.Runtime

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

  test "kinds lists only runtimes with an executor today" do
    assert Runtime.kinds() == ["docker"]
  end

  test "rejects an unsupported harness runtime kind at config load", ctx do
    invalid =
      fixture(ctx)
      |> put_in(["harnesses", "opencode", "runtime"], "kata")

    assert_raise Error, ~r/unsupported runtime "kata"/, fn ->
      Config.load_map!(invalid, path: Path.join(ctx.root, "omashiki.toml"))
    end
  end

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
        "global" => %{"host" => "~/.cache/omashiki/runtime-test"}
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
          "policy" => %{"mode" => "allowlist"},
          "network" => "restricted",
          "resources" => %{"cpus" => 2.0, "memory" => "2GB", "pids" => 256}
        }
      }
    }
  end
end
