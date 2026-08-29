defmodule Omashiki.Jobs.SinkTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs.{Admission, Job, WorkArtifact}
  alias Omashiki.Jobs.Contract.V1

  setup do
    root =
      Path.join(System.tmp_dir!(), "omashiki-sink-#{System.unique_integer([:positive])}")

    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    copy_plugins!(root)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])
    state_path = Path.join(root, "provider-state.json")
    File.write!(state_path, "{}")

    load_config = fn ->
      Config.load_map!(config_map(state_path), path: Path.join(root, "omashiki.toml"))
    end

    load_config.()

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, token: token, load_config: load_config, repo_path: repo_path}
  end

  test "git sink without repository is rejected", %{token: token} do
    request =
      single_request()
      |> Map.delete("repo")

    assert {:error, :repository_required} = Admission.admit(token, request)
  end

  test "none sink with repository is rejected", %{token: token} do
    assert {:error, :repository_not_allowed} =
             Admission.admit(token, single_request("none-env", "app"))
  end

  test "files sink with repository is rejected", %{token: token} do
    assert {:error, :repository_not_allowed} =
             Admission.admit(token, single_request("files-env", "app"))
  end

  test "files sink without repository is admitted", %{token: token} do
    request = single_request("files-env") |> Map.delete("repo")

    assert {:ok, job} = Admission.admit(token, request)
    assert is_nil(job.repository)
    assert is_nil(job.admitted_repository)
    assert job.admitted_environment["sink"] == "files"
  end

  test "succeeded none persists terminal_result without git shas", %{token: token} do
    request = single_request("none-env") |> Map.delete("repo")
    assert {:ok, job} = Admission.admit(token, request)
    assert {:ok, attempt} = Omashiki.Jobs.claim(job, "sink-runner")

    result = %{"summary" => "done"}

    assert {:ok, completed_attempt} =
             Omashiki.Jobs.complete(attempt, attempt.lease_token, :succeeded, %{result: result})

    updated = Repo.get!(Job, job.id)
    assert updated.status == "succeeded"
    assert updated.terminal_result == result
    assert completed_attempt.branch == nil
    assert completed_attempt.base_sha == nil
    assert completed_attempt.head_sha == nil
    assert completed_attempt.worktree_clean == nil
    assert completed_attempt.result == result
  end

  test "git sink cannot succeed without git fields", %{token: token} do
    assert {:ok, job} = Admission.admit(token, single_request("git-env", "app"))
    assert {:ok, attempt} = Omashiki.Jobs.claim(job, "sink-runner")

    assert {:error, :invalid_success_result} =
             Omashiki.Jobs.complete(attempt, attempt.lease_token, :succeeded, %{
               result: %{"summary" => "done"}
             })
  end

  test "none sink cannot succeed with git fields", %{token: token} do
    request = single_request("none-env") |> Map.delete("repo")
    assert {:ok, job} = Admission.admit(token, request)
    assert {:ok, attempt} = Omashiki.Jobs.claim(job, "sink-runner")

    assert {:error, :invalid_success_result} =
             Omashiki.Jobs.complete(attempt, attempt.lease_token, :succeeded, %{
               result: %{"summary" => "done"},
               branch: "jobs/sink",
               base_sha: String.duplicate("a", 40),
               head_sha: String.duplicate("b", 40),
               worktree_clean: true
             })
  end

  test "provision rejects environment missing sink", %{token: token} do
    assert {:ok, job} = Admission.admit(token, single_request("git-env", "app"))
    assert {:ok, attempt} = Omashiki.Jobs.claim(job, "sink-runner")

    environment = job.admitted_environment |> Map.delete("sink") |> Map.delete(:sink)

    assert {:error, {:unsupported_sink, :missing}} =
             Omashiki.Jobs.Runner.DockerContainer.provision(job, attempt, environment, [])
  end

  test "validate still fails files sink on secret in blob" do
    job = %Job{id: Ecto.UUID.generate(), current_attempt: 1}

    {:ok, %{artifact: artifact}} =
      WorkArtifact.provision(job, "files", [], fn _artifact -> {:ok, %{}} end)

    File.write!(Path.join(artifact.path, "leak.txt"), "api_key=super-secret-value\n")

    assert {:error, {:likely_secret, "leak.txt"}} = WorkArtifact.finalize(artifact, job)
    assert :ok = WorkArtifact.cleanup(artifact)
  end

  test "contract accepts succeeded result without git fields" do
    result = %{
      "schema_version" => 1,
      "job_id" => Ecto.UUID.generate(),
      "attempt" => 1,
      "status" => "succeeded",
      "result" => %{"summary" => "done"},
      "finished_at" => "2026-08-24T03:00:00Z"
    }

    assert {:ok, ^result} = V1.validate_result(result)
  end

  defp config_map(state_path) do
    %{
      "repositories" => %{
        "app" => %{"path" => "repo", "base_branch" => "main"}
      },
      "presets" => %{"opencode" => %{"plugin" => "opencode", "options" => %{}}},
      "runtimes" => %{
        "docker" => %{
          "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
        }
      },
      "credentials" => %{
        "secret" => %{
          "provider" => "anthropic",
          "model" => "test",
          "api_key" => "do-not-persist"
        }
      },
      "environments" => %{
        "git-env" => env("git", state_path),
        "files-env" => env("files", state_path),
        "none-env" => env("none", state_path)
      },
      "limits" => %{}
    }
  end

  defp env(sink, state_path) do
    %{
      "runtime" => "docker.runc.debian",
      "sink" => sink,
      "packages" => [],
      "preset" => "opencode",
      "executables" => ["git"],
      "credentials" => ["secret"],
      "timeout_ms" => 1_000,
      "caches" => [],
      "mounts" => [
        %{
          "source" => state_path,
          "target" => "/run/omashiki/state/provider-state.json",
          "read_only" => false
        }
      ],
      "pre_steps" => [],
      "post_steps" => [],
      "policy" => %{"mode" => "off"},
      "network" => "none",
      "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
    }
  end

  defp single_request(environment \\ "git-env", repo \\ nil) do
    %{
      "schema_version" => 1,
      "idempotency_key" => "sink-#{System.unique_integer([:positive])}",
      "correlation_id" => "sink-workflow",
      "environment" => environment,
      "payload" => %{"instruction" => "run", "branch" => "feat-test"},
      "priority" => 1
    }
    |> maybe_put("repo", repo)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
