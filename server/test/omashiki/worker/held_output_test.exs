defmodule Omashiki.Worker.HeldOutputTest do
  @moduledoc """
  A worker holds output the secret scan refused, and settles it through the
  manager that offered the attempt. The manager here is this house's own
  endpoint, reached over HTTP through Bypass.
  """

  use OmashikiWeb.ConnCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Admission, HeldOutput, Job, JobAttempt}
  alias Omashiki.Jobs.HeldOutput.Sweeper
  alias Omashiki.LeakyContainer
  alias Omashiki.Repo
  alias Omashiki.Worker.{Complete, Inbox, Offer, Snapshot}

  defmodule FakeHarness do
    def invoke(_invocation, _context),
      do: {:ok, %Omashiki.Harness.Result{assistant_text: "wrote the notes"}}
  end

  setup %{token: token} do
    root = Path.join(System.tmp_dir!(), "omashiki-held-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Config.load_map!(
      %{
        "presets" => %{"opencode" => %{"plugin" => "opencode", "options" => %{}}},
        "runtimes" => %{
          "docker" => %{
            "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
          }
        },
        "environments" => %{
          "notes" => %{
            "runtime" => "docker.runc.debian",
            "sink" => "files",
            "packages" => [],
            "preset" => "opencode",
            "executables" => [],
            "timeout_ms" => 1_000,
            "caches" => [],
            "mounts" => [],
            "policy" => %{"mode" => "off"},
            "network" => "none",
            "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
          }
        },
        "limits" => %{}
      },
      path: Path.join(root, "omashiki.toml")
    )

    {:ok, _capacity} = Jobs.sync_capacity()

    worker_token = "worker-held-#{System.unique_integer([:positive])}"
    bypass = Bypass.open()
    manager = OmashikiWeb.Endpoint.init([])

    for {method, path} <- [
          {"POST", "/internal/work/heartbeat"},
          {"POST", "/internal/work/complete"},
          {"PUT", "/internal/work/blobs/:job_id"}
        ] do
      Bypass.stub(bypass, method, path, &OmashikiWeb.Endpoint.call(&1, manager))
    end

    env = [
      held_output_root: Path.join(root, "held"),
      worker_token: worker_token,
      worker_managers: [
        %{"id" => "house-a", "url" => "http://127.0.0.1:#{bypass.port}", "token" => worker_token}
      ],
      worker_state_path: Path.join(root, "worker-state.json")
    ]

    previous = for {key, _value} <- env, do: {key, Application.get_env(:omashiki, key)}
    Enum.each(env, fn {key, value} -> Application.put_env(:omashiki, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:omashiki, key)
        {key, value} -> Application.put_env(:omashiki, key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, _, job} =
      Admission.admit_once(token, %{
        "idempotency_key" => "held-#{System.unique_integer([:positive])}",
        "correlation_id" => "held",
        "environment" => "notes",
        "payload" => %{"instruction" => "write notes"},
        "priority" => 0
      })

    {:ok, job: job, worker_token: worker_token, bypass: bypass}
  end

  test "the worker holds the output and publishes it once approved", %{
    conn: conn,
    job: job,
    worker_token: worker_token
  } do
    {offer, record} = hold_on_worker(conn, worker_token)

    job = Repo.get!(Job, job.id)
    assert job.status == "review"
    assert job.review["node"] == "worker-a"
    assert record.manager_id == "house-a"
    assert record.token == offer.lease_token

    # Node and house take the deadline from the same admitted environment.
    {:ok, house_deadline, _offset} = DateTime.from_iso8601(job.review["expires_at"])
    assert abs(DateTime.diff(house_deadline, record.expires_at, :second)) < 60

    assert_in_delta DateTime.diff(record.expires_at, DateTime.utc_now(), :day), 7, 1

    assert Sweeper.settle(record) == :held
    assert File.exists?(record.artifact.path)

    {:ok, _approved} = Jobs.approve(job, "alice")
    assert Sweeper.settle(record) == :published

    job = Repo.get!(Job, job.id)
    assert job.status == "succeeded"
    assert File.exists?(job.terminal_result["blob_path"])
    refute File.exists?(record.artifact.path)
    assert HeldOutput.list() == []
  end

  test "the worker removes the output once rejected", %{
    conn: conn,
    job: job,
    worker_token: worker_token
  } do
    {_offer, record} = hold_on_worker(conn, worker_token)

    {:ok, %Job{status: "failed"}} = Jobs.reject(job, "alice")
    assert Sweeper.settle(record) == {:discarded, :cancelled}
    refute File.exists?(record.artifact.path)
    assert HeldOutput.list() == []
  end

  test "the worker removes the output when the manager refuses its token", %{
    conn: conn,
    job: job,
    worker_token: worker_token
  } do
    {_offer, record} = hold_on_worker(conn, worker_token)
    [manager] = Application.get_env(:omashiki, :worker_managers)
    Application.put_env(:omashiki, :worker_managers, [%{manager | "token" => "revoked"}])

    assert Sweeper.settle(record) == {:discarded, :unauthorized}
    refute File.exists?(record.artifact.path)
    assert HeldOutput.list() == []
    assert Repo.get!(Job, job.id).status == "review"
  end

  test "the worker removes the output when the manager no longer knows the attempt", %{
    conn: conn,
    job: job,
    worker_token: worker_token
  } do
    {_offer, record} = hold_on_worker(conn, worker_token)
    Repo.delete!(Repo.get!(Job, job.id))

    assert Sweeper.settle(record) == {:discarded, :cancelled}
    refute File.exists?(record.artifact.path)
    assert HeldOutput.list() == []
  end

  test "the worker keeps the output while the manager is unreachable before the deadline", %{
    conn: conn,
    worker_token: worker_token,
    bypass: bypass
  } do
    {_offer, record} = hold_on_worker(conn, worker_token)
    Bypass.down(bypass)

    assert {:error, _unreachable} = Sweeper.settle(record)
    assert File.exists?(record.artifact.path)
    assert HeldOutput.list() == [record]

    # A manager the worker no longer serves is no answer either.
    Application.put_env(:omashiki, :worker_managers, [])
    assert {:error, {:manager_not_enrolled, "house-a"}} = Sweeper.settle(record)
    assert File.exists?(record.artifact.path)
  end

  test "the worker removes the output past its deadline while the manager is unreachable", %{
    conn: conn,
    worker_token: worker_token,
    bypass: bypass
  } do
    {_offer, record} = hold_on_worker(conn, worker_token)
    Bypass.down(bypass)

    # Past the deadline but within the grace, the house may still decide.
    record = expire(record, DateTime.add(DateTime.utc_now(), -5, :minute))
    assert {:error, _unreachable} = Sweeper.settle(record)
    assert File.exists?(record.artifact.path)

    record = expire(record, DateTime.add(DateTime.utc_now(), -2, :hour))
    assert Sweeper.settle(record) == {:discarded, :expired}
    refute File.exists?(record.artifact.path)
    assert HeldOutput.list() == []
  end

  test "a held heartbeat renews no lease and answers with the decision", %{
    conn: conn,
    job: job,
    worker_token: worker_token
  } do
    {:ok, %{offer: map}} = Inbox.poll("worker-a", 1)
    body = %{"attempt_id" => map["attempt_id"], "lease_token" => map["lease_token"]}
    attempt = Repo.get!(JobAttempt, map["attempt_id"])

    # While the attempt runs, a held ask keeps the output and leaves the lease alone.
    assert %{"cancel" => false, "publish" => false} =
             heartbeat(conn, worker_token, Map.put(body, "held", true))

    assert Repo.get!(JobAttempt, attempt.id).lease_expires_at == attempt.lease_expires_at

    error = %{"code" => "secret_found", "message" => "held", "details" => %{}}
    {:ok, _held} = Jobs.hold(attempt.id, attempt.lease_token, error)
    {:ok, _approved} = Jobs.approve(job, "alice")

    assert %{"cancel" => false, "publish" => true} =
             heartbeat(conn, worker_token, Map.put(body, "held", true))

    # Without `held`, the ask is a running attempt's heartbeat, which a held attempt fails.
    assert %{"cancel" => true} = heartbeat(conn, worker_token, body)
  end

  defp hold_on_worker(conn, worker_token) do
    {:ok, %{offer: map}} = Inbox.poll("worker-a", 1)
    {:ok, offer} = Offer.from_map(map)
    offer = %{offer | manager_id: "house-a"}

    assert {:ok, %Complete{kind: :review} = complete} =
             Snapshot.run(offer, container: LeakyContainer, adapter: FakeHarness)

    assert complete.code == "secret_found"
    assert [record] = HeldOutput.list()

    response =
      conn
      |> worker_conn(worker_token)
      |> post("/internal/work/complete", %{
        "attempt_id" => offer.attempt_id,
        "lease_token" => offer.lease_token,
        "complete" => Complete.to_map(complete)
      })

    assert json_response(response, 200) == %{"ok" => true}
    {offer, record}
  end

  # Rewrite the record on disk with another deadline and read it back.
  defp expire(record, expires_at) do
    file = Path.join(HeldOutput.root(), "#{record.attempt_id}.json")

    file
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("expires_at", DateTime.to_iso8601(expires_at))
    |> then(&File.write!(file, Jason.encode!(&1)))

    [record] = HeldOutput.list()
    record
  end

  defp heartbeat(conn, worker_token, body) do
    conn
    |> worker_conn(worker_token)
    |> post("/internal/work/heartbeat", body)
    |> json_response(200)
  end

  defp worker_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end
end
