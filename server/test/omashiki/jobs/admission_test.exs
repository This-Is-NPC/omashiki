defmodule Omashiki.Jobs.AdmissionTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.ApiTokens.Token
  alias Omashiki.Config
  alias Omashiki.Config.Rollout
  alias Omashiki.Credentials
  alias Omashiki.Jobs.{Admission, Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  setup do
    root =
      Path.join(System.tmp_dir!(), "omashiki-admission-#{System.unique_integer([:positive])}")

    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    copy_plugins!(root)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])
    state_path = Path.join(root, "provider-state.json")
    File.write!(state_path, "{}")

    load_config = fn model ->
      Config.load_map!(config_map(state_path, model), path: Path.join(root, "omashiki.toml"))
    end

    load_config.("test")

    user = user_fixture()
    {token, plaintext} = api_token_fixture(user)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, token: token, plaintext: plaintext, load_config: load_config}
  end

  defp config_map(state_path, model) do
    %{
      "repositories" => %{
        "app" => %{
          "path" => "repo",
          "base_branch" => "main",
          "remote" => "/srv/canonical/app.git"
        }
      },
      "presets" => %{
        "opencode" => %{"plugin" => "opencode", "options" => %{}}
      },
      "credentials" => %{
        "secret" => %{
          "provider" => "anthropic",
          "model" => model,
          "api_key" => "do-not-persist"
        }
      },
      "environments" => %{
        "safe" => %{
          "isolation" => "docker",
          "image" => "omashiki/agent:latest",
          "sink" => "git",
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
      },
      "limits" => %{}
    }
  end

  test "rejects git sink jobs without branch or title", %{token: token} do
    assert {:error, :task_branch_required} =
             Admission.admit(
               token,
               Map.put(single_request(), "payload", %{"instruction" => "run"})
             )
  end

  test "admits git sink jobs with title-only cascade to task_branch slug", %{token: token} do
    payload = %{"instruction" => "run", "title" => "Hello World"}

    assert {:ok, job} =
             Admission.admit(
               token,
               single_request(%{"payload" => payload, "idempotency_key" => "title-only"})
             )

    assert job.payload == payload
    assert job.admitted_repository["task_branch"] == "hello-world"
  end

  test "admits a root job with an immutable redacted snapshot", %{token: token} do
    assert {:ok, job} = Admission.admit(token, single_request())
    assert job.status == "queued"
    assert job.payload == %{"instruction" => "run", "branch" => "feat-test"}
    assert job.payload_hash == sha256(Jason.encode!(job.payload))
    assert job.admitted_repository["name"] == "app"

    # The key GitArtifact reads to find the canonical remote. Losing it here
    # silently downgrades every job to a local-only, unreachable artifact.
    assert job.admitted_repository["remote"] == "/srv/canonical/app.git"
    assert job.admitted_repository["task_branch"] == "feat-test"

    assert job.admitted_environment["name"] == "safe"
    assert [%{"read_only" => false}] = job.admitted_environment["mounts"]
    refute inspect(job.admitted_environment) =~ "do-not-persist"

    assert %{"path" => path, "contents" => contents, "digest" => plugin_digest} =
             job.admitted_plugin

    assert is_binary(path) and path != ""
    assert is_binary(contents) and contents != ""
    assert byte_size(plugin_digest) == 64
    assert plugin_digest == :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    assert byte_size(job.admitted_plugin_digest) == 64
    refute job.admitted_plugin_digest == plugin_digest

    assert Repo.aggregate(from(a in JobAttempt, where: a.job_id == ^job.id), :count, :id) == 1
    assert Repo.aggregate(from(e in JobEvent, where: e.job_id == ^job.id), :count, :event_id) == 1

    assert Repo.aggregate(Oban.Job, :count, :id) == 1
  end

  # A drain-all rollout is waiting for the fleet to empty. Admitting here would
  # keep it from ever emptying, so the door closes at the front of the system.
  test "a drain-all rollout refuses admission until the swap lands", %{token: token} do
    previous = Application.get_env(:omashiki, :rollout_attempt_counter)
    Application.put_env(:omashiki, :rollout_attempt_counter, {__MODULE__, :busy_fleet, []})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:omashiki, :rollout_attempt_counter, previous),
        else: Application.delete_env(:omashiki, :rollout_attempt_counter)

      set_fleet(0)
    end)

    set_fleet(1)

    assert {:ok, :draining} =
             Rollout.reload(Rollout,
               mode: :drain_all,
               drain_timeout_ms: 30_000,
               path: "/nonexistent"
             )

    refute Rollout.admission_open?()
    assert {:error, :admission_paused} = Admission.admit(token, single_request())
    assert {:error, :admission_paused} = Admission.admit_batch(token, batch_request())
    assert Repo.aggregate(Job, :count, :id) == 0

    set_fleet(0)
    assert eventually(fn -> Rollout.admission_open?() end)
    assert {:ok, %Job{}} = Admission.admit(token, single_request())
  end

  # The digest is captured so a reload cannot move the ground under an admitted
  # job. That guarantee is only real if the things that *read* configuration on
  # the attempt path read the capture rather than the live generation — the
  # model above all, since swapping it is the operator gesture this exists for.
  test "the model a job was admitted with survives a hot swap",
       %{token: token, load_config: load_config} do
    assert {:ok, job} = Admission.admit(token, single_request())
    assert [%{"name" => "secret", "model" => "test"}] = job.admitted_environment["credentials"]

    load_config.("swapped-after-admission")

    assert %{model: "swapped-after-admission"} = Config.get_credential("secret")

    pinned = Credentials.admitted(job.admitted_environment, "secret")
    assert pinned.model == "test"
    assert pinned.provider == "anthropic"

    # The one field that is *not* pinned, and must not be: admission strips it
    # so a live key never reaches a database column, so it can only come from
    # the live generation.
    assert pinned.api_key == "do-not-persist"

    # Newly admitted work does get the swap, with no restart in between.
    assert {:ok, next} =
             Admission.admit(token, single_request(%{"idempotency_key" => "request-2"}))

    assert [%{"model" => "swapped-after-admission"}] = next.admitted_environment["credentials"]
  end

  @doc false
  def busy_fleet do
    case :persistent_term.get({__MODULE__, :fleet}, 0) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp set_fleet(n), do: :persistent_term.put({__MODULE__, :fleet}, n)

  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  test "rejects malformed, unknown, and oversized submissions without writes", %{token: token} do
    assert {:error, {:validation, errors}} = Admission.admit(token, %{})
    assert %{field: "environment", code: "required"} in errors

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
    exact = %{"instruction" => String.duplicate("x", 128), "branch" => "feat-exact"}
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
    assert root.correlation_id == child.correlation_id
    assert Repo.aggregate(Oban.Job, :count, :id) == 1

    assert Repo.all(from(e in JobEvent, order_by: e.sequence, select: e.status)) == [
             "queued",
             "blocked"
           ]
  end

  test "batch validation and registry failures write nothing", %{token: token} do
    invalid = Map.put(batch_request(), "jobs", [batch_job("child", [%{"ref" => "unknown"}])])
    assert {:error, {:validation, errors}} = Admission.admit_batch(token, invalid)
    assert %{code: "unknown_ref"} = Enum.find(errors, &(&1.code == "unknown_ref"))

    assert Repo.aggregate(Job, :count, :id) == 0
    assert Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  test "rejects a cyclic batch before the transaction starts", %{token: token} do
    cyclic =
      Map.put(batch_request(), "jobs", [batch_job("a", [%{"ref" => "b"}]), batch_job("b", [%{"ref" => "a"}])])

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
        "payload" => %{"instruction" => "run", "branch" => "feat-test"},
        "priority" => 1
      },
      overrides
    )
  end

  defp batch_request do
    %{
      "schema_version" => 1,
      "correlation_id" => "batch-1",
      "jobs" => [batch_job("root", []), batch_job("child", [%{"ref" => "root"}])]
    }
  end

  defp batch_job(ref, depends_on \\ []) do
    %{
      "ref" => ref,
      "idempotency_key" => "batch-#{ref}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{
        "instruction" => "run",
        "context" => %{"ref" => ref},
        "branch" => "feat-batch-#{ref}"
      },
      "priority" => 0
    }
    |> then(fn job -> Map.put(job, "depends_on", depends_on) end)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
