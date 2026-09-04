defmodule Omashiki.Worker.SnapshotTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Worker.{Complete, Offer, Snapshot}

  @remote "https://example.com/repo.git"

  defmodule FakeHarness do
    def invoke(invocation, _context),
      do: {:ok, %Omashiki.Harness.Result{assistant_text: invocation.instruction || "ok"}}
  end

  defmodule GitContainer do
    @remote "https://example.com/repo.git"

    def provision(job, _attempt, _environment, _opts) do
      send(self(), {:provision, job})
      {:ok, %{id: "git-fake", artifact: %{task_branch: "feat-runner"}}}
    end

    def exec(_container, _argv, _timeout_ms), do: {:ok, %{exit_status: 0, output: ""}}

    def finalize(_container, _job, _opts) do
      {:ok,
       %{
         remote: @remote,
         branch: "jobs/fake",
         base_sha: String.duplicate("a", 40),
         head_sha: String.duplicate("b", 40)
       }}
    end

    def destroy(_container) do
      send(self(), :destroyed)
      :ok
    end
  end

  defmodule FilesContainer do
    def provision(_job, _attempt, _environment, _opts),
      do: {:ok, %{id: "files-fake"}}

    def exec(_container, _argv, _timeout_ms), do: {:ok, %{exit_status: 0, output: ""}}

    def finalize(_container, _job, _opts) do
      {:ok,
       %{
         result: %{
           "sink" => "files",
           "changed_bytes" => 1,
           "blob_digest" => "abc",
           "blob_path" => "/tmp/x"
         }
       }}
    end

    def destroy(_container), do: :ok
  end

  defmodule NoneContainer do
    def provision(_job, _attempt, _environment, _opts),
      do: {:ok, %{id: "none-fake"}}

    def exec(_container, _argv, _timeout_ms), do: {:ok, %{exit_status: 0, output: ""}}

    def finalize(_container, _job, _opts) do
      {:ok, %{result: %{"sink" => "none", "changed_bytes" => 0}}}
    end

    def destroy(_container), do: :ok
  end

  defmodule FailingContainer do
    def provision(_job, _attempt, _environment, _opts), do: {:error, :provision_failed}
    def exec(_container, _argv, _timeout_ms), do: {:error, :not_reached}
    def finalize(_container, _job, _opts), do: {:error, :not_reached}
    def destroy(_container), do: :ok
  end

  defmodule SpyContainer do
    def provision(_job, _attempt, _environment, _opts) do
      send(self(), :provision_called)
      {:ok, %{}}
    end

    def exec(_container, _argv, _timeout_ms), do: {:ok, %{}}
    def finalize(_container, _job, _opts), do: {:ok, %{}}
    def destroy(_container), do: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "snapshot-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "presets" => %{"opencode" => %{"plugin" => "opencode", "options" => %{}}},
        "runtimes" => %{
          "docker" => %{
            "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
          }
        },
        "environments" => %{
          "safe" => %{
            "runtime" => "docker.runc.debian",
            "sink" => "git",
            "packages" => [],
            "preset" => "opencode",
            "executables" => ["git"],
            "timeout_ms" => 1_000,
            "caches" => [],
            "mounts" => [],
            "pre_steps" => [],
            "post_steps" => [],
            "policy" => %{"mode" => "off"},
            "network" => "none",
            "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
          },
        },
        "limits" => %{}
      },
      path: Path.join(root, "omashiki.toml")
    )

    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:omashiki, :worker_snapshot_opts,
      container: GitContainer,
      adapter: FakeHarness
    )

    on_exit(fn -> Application.delete_env(:omashiki, :worker_snapshot_opts) end)

    :ok
  end

  test "git offer completes with mirror path and git metadata" do
    offer =
      base_offer(%{
        sink: "git",
        admitted_environment: environment_for("git"),
        admitted_repository: git_repository()
      })

    assert {:ok, %Complete{kind: :git} = complete} = Snapshot.run(offer)
    assert complete.remote == @remote
    assert complete.branch == "jobs/fake"
    assert complete.base_sha == String.duplicate("a", 40)
    assert complete.head_sha == String.duplicate("b", 40)

    mirror = mirror_path(@remote)

    assert_receive {:provision, job}
    assert job.admitted_repository["path"] == mirror
    assert_receive :destroyed
  end

  test "git mirror path includes manager_id when set on offer" do
    offer =
      base_offer(%{
        sink: "git",
        manager_id: "mgr-a",
        admitted_environment: environment_for("git"),
        admitted_repository: git_repository()
      })

    assert {:ok, %Complete{kind: :git}} = Snapshot.run(offer)

    assert_receive {:provision, job}
    assert job.admitted_repository["path"] == mirror_path(@remote, "mgr-a")
    refute job.admitted_repository["path"] == mirror_path(@remote, "mgr-b")
    assert_receive :destroyed
  end

  test "files offer completes with files metadata" do
    Application.put_env(:omashiki, :worker_snapshot_opts,
      container: FilesContainer,
      adapter: FakeHarness
    )

    offer =
      base_offer(%{
        sink: "files",
        admitted_environment: environment_for("files"),
        admitted_repository: nil,
        admitted_repository_digest: nil,
        repository: nil
      })

    assert {:ok, %Complete{kind: :files, changed_bytes: 1, blob_digest: "abc", blob_path: "/tmp/x"}} =
             Snapshot.run(offer)
  end

  test "none offer completes with changed bytes" do
    Application.put_env(:omashiki, :worker_snapshot_opts,
      container: NoneContainer,
      adapter: FakeHarness
    )

    offer =
      base_offer(%{
        sink: "none",
        admitted_environment: environment_for("none"),
        admitted_repository: nil,
        admitted_repository_digest: nil,
        repository: nil
      })

    assert {:ok, %Complete{kind: :none, changed_bytes: 0}} = Snapshot.run(offer)
  end

  test "dependency base is refused before provisioning" do
    Application.put_env(:omashiki, :worker_snapshot_opts, container: SpyContainer, adapter: FakeHarness)

    offer =
      base_offer(%{
        admitted_repository:
          git_repository()
          |> Map.put("base", "dependency:00000000-0000-0000-0000-000000000001")
      })

    assert {:error, :unresolved_dependency} = Snapshot.run(offer)
    refute_receive :provision_called, 50
  end

  test "provision errors bubble up" do
    Application.put_env(:omashiki, :worker_snapshot_opts,
      container: FailingContainer,
      adapter: FakeHarness
    )

    offer = base_offer(%{admitted_repository: git_repository()})

    assert {:error, :provision_failed} = Snapshot.run(offer)
  end

  test "does not reference Repo" do
    source = File.read!(Path.join(["lib", "omashiki", "worker", "snapshot.ex"]))
    refute source =~ "Repo"
  end

  defp base_offer(overrides) do
    n = System.unique_integer([:positive])

    defaults = %{
      job_id: "job-#{n}",
      attempt_id: "attempt-#{n}",
      lease_token: "lease-#{n}",
      sink: "git",
      payload: %{"instruction" => "run"},
      admitted_environment: environment_for("git"),
      admitted_repository: git_repository(),
      admitted_plugin: %{
        "path" => "plugins/fake.toml",
        "contents" => "",
        "digest" => String.duplicate("e", 64)
      },
      registry_digest: String.duplicate("d", 64),
      timeout_ms: 1_000,
      attempt_number: 1,
      user_id: Ecto.UUID.generate(),
      repository: "app",
      environment: "safe",
      admitted_environment_digest: String.duplicate("c", 64),
      admitted_repository_digest: String.duplicate("b", 64),
      admitted_plugin_digest: String.duplicate("e", 64)
    }

    struct(Offer, Map.merge(defaults, overrides))
  end

  defp git_repository do
    %{
      "remote" => @remote,
      "task_branch" => "feat-runner",
      "base_branch" => "main",
      "base" => "main",
      "path" => "/manager/wrong/path"
    }
  end

  defp mirror_path(remote, manager_id \\ "local") do
    short =
      :crypto.hash(:sha256, remote) |> Base.encode16(case: :lower) |> String.slice(0, 16)

    Path.join([System.user_home!(), ".cache", "omashiki", "mirrors", manager_id, short])
  end

  defp environment_for("git") do
    {:ok, resolved} = Config.resolve_job("app", "safe")
    resolved.environment
  end

  defp environment_for(sink) do
    %{environment_for("git") | sink: sink}
  end
end
