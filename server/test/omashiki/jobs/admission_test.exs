defmodule Omashiki.Jobs.AdmissionTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.ApiTokens.Token
  alias Omashiki.Config
  alias Omashiki.Jobs.{Admission, Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  setup do
    root =
      Path.join(System.tmp_dir!(), "omashiki-admission-#{System.unique_integer([:positive])}")

    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])
    state_path = Path.join(root, "provider-state.json")
    File.write!(state_path, "{}")

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "harnesses" => %{
          "opencode" => %{
            "adapter" => "opencode",
            "runtime" => "docker",
            "image" => "agent:latest"
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
          "safe" => %{
            "harness" => "opencode",
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
        },
        "limits" => %{}
      },
      path: Path.join(root, "omashiki.toml")
    )

    user = user_fixture()
    {token, plaintext} = api_token_fixture(user)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, token: token, plaintext: plaintext}
  end

  test "admits a root job with an immutable redacted snapshot", %{token: token} do
    assert {:ok, job} = Admission.admit(token, single_request())
    assert job.status == "queued"
    assert job.payload == %{"instruction" => "run"}
    assert job.payload_hash == sha256(Jason.encode!(job.payload))
    assert job.repository_snapshot["name"] == "app"
    assert job.environment_snapshot["name"] == "safe"
    assert [%{"read_only" => false}] = job.environment_snapshot["mounts"]
    refute inspect(job.environment_snapshot) =~ "do-not-persist"

    assert Repo.aggregate(from(a in JobAttempt, where: a.job_id == ^job.id), :count, :id) == 1
    assert Repo.aggregate(from(e in JobEvent, where: e.job_id == ^job.id), :count, :event_id) == 1

    assert Repo.aggregate(Oban.Job, :count, :id) == 1
  end

  test "rejects malformed, unknown, and oversized submissions without writes", %{token: token} do
    assert {:error, {:validation, errors}} = Admission.admit(token, %{})
    assert %{field: "repo", code: "required"} in errors

    assert {:error, :unknown_repository} =
             Admission.admit(token, Map.put(single_request(), "repo", "missing"))

    oversized = %{
      "instruction" => "run",
      "context" => %{
        "data" => String.duplicate("x", Omashiki.Jobs.Contract.V1.max_payload_bytes())
      }
    }

    assert {:error, {:validation, errors}} =
             Admission.admit(token, Map.put(single_request(), "payload", oversized))

    assert %{field: "payload.context", code: "too_large"} in errors
    assert Repo.aggregate(Job, :count, :id) == 0
    assert Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  test "accepts exactly 1 MiB of encoded payload and rejects the next byte", %{token: token} do
    exact = %{"instruction" => String.duplicate("x", 128)}
    assert {:ok, job} = Admission.admit(token, Map.put(single_request(), "payload", exact))
    assert job.payload == exact

    oversized = %{
      "instruction" => String.duplicate("x", Omashiki.Jobs.Contract.V1.max_payload_bytes() + 1)
    }

    assert {:error, {:validation, errors}} =
             Admission.admit(token, Map.put(single_request("next"), "payload", oversized))

    assert %{field: "payload.instruction", code: "too_large"} in errors
  end

  test "rejects a token that is not active or persisted", %{token: token} do
    Repo.update_all(from(t in Token, where: t.id == ^token.id),
      set: [revoked_at: DateTime.utc_now(:microsecond)]
    )

    assert {:error, :unauthorized} = Admission.admit(token, single_request())
  end

  test "duplicate idempotency returns the original without side effects", %{token: token} do
    assert {:ok, original} = Admission.admit(token, single_request())
    assert {:ok, duplicate} = Admission.admit(token, single_request())
    assert duplicate.id == original.id

    assert Repo.aggregate(from(e in JobEvent, where: e.job_id == ^original.id), :count, :event_id) ==
             1

    assert Repo.aggregate(Oban.Job, :count, :id) == 1
  end

  test "same-owner tokens cannot reuse another token's idempotency key", %{token: token} do
    user = Repo.get!(Omashiki.Accounts.User, token.user_id)
    {other_token, _plaintext} = api_token_fixture(user)

    assert {:ok, _original} = Admission.admit(token, single_request())
    assert {:error, :idempotency_conflict} = Admission.admit(other_token, single_request())
  end

  test "admits a batch atomically and queues only roots", %{token: token} do
    assert {:ok, [root, child]} = Admission.admit_batch(token, batch_request())
    assert root.status == "queued"
    assert child.status == "blocked"
    assert child.parent_job_id == root.id
    assert root.correlation_id == child.correlation_id
    assert Repo.aggregate(Oban.Job, :count, :id) == 1

    assert Repo.all(from(e in JobEvent, order_by: e.sequence, select: e.status)) == [
             "queued",
             "blocked"
           ]
  end

  test "batch validation and registry failures write nothing", %{token: token} do
    invalid = Map.put(batch_request(), "jobs", [batch_job("child", "unknown")])
    assert {:error, {:validation, errors}} = Admission.admit_batch(token, invalid)
    assert %{code: "unknown_ref"} = Enum.find(errors, &(&1.code == "unknown_ref"))

    assert Repo.aggregate(Job, :count, :id) == 0
    assert Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  test "rejects a cyclic batch before the transaction starts", %{token: token} do
    cyclic =
      Map.put(batch_request(), "jobs", [batch_job("a", "b"), batch_job("b", "a")])

    assert {:error, {:validation, errors}} = Admission.admit_batch(token, cyclic)
    assert %{code: "cycle"} = Enum.find(errors, &(&1.code == "cycle"))
    assert Repo.aggregate(Job, :count, :id) == 0
    assert Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  test "concurrent duplicate submissions create one job, event, and oban row", %{token: token} do
    results =
      1..2
      |> Task.async_stream(fn _ -> Admission.admit(token, single_request()) end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Job{}}, &1))
    assert Repo.aggregate(Job, :count, :id) == 1
    assert Repo.aggregate(JobEvent, :count, :event_id) == 1
    assert Repo.aggregate(Oban.Job, :count, :id) == 1
  end

  defp single_request(overrides \\ %{})

  defp single_request("next"), do: single_request(%{"idempotency_key" => "request-next"})

  defp single_request(overrides) do
    Map.merge(
      %{
        "schema_version" => 1,
        "idempotency_key" => "request-1",
        "correlation_id" => "correlation-1",
        "repo" => "app",
        "environment" => "safe",
        "payload" => %{"instruction" => "run"},
        "priority" => 1
      },
      overrides
    )
  end

  defp batch_request do
    %{
      "schema_version" => 1,
      "correlation_id" => "batch-1",
      "jobs" => [batch_job("root"), batch_job("child", "root")]
    }
  end

  defp batch_job(ref, parent_ref \\ nil) do
    %{
      "ref" => ref,
      "idempotency_key" => "batch-#{ref}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{"instruction" => "run", "context" => %{"ref" => ref}},
      "priority" => 0
    }
    |> then(fn job -> if parent_ref, do: Map.put(job, "parent_ref", parent_ref), else: job end)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
