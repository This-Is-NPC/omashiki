defmodule OmashikiWeb.Api.WorkControllerTest do
  use OmashikiWeb.ConnCase, async: false

  import Omashiki.JobFixtures
  import Ecto.Query

  alias Omashiki.Jobs
  alias Omashiki.Config
  alias Omashiki.Jobs.ExecutionCapacity
  alias Omashiki.Jobs.Job
  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Repo
  alias Omashiki.Worker.Inbox

  @worker_poll "/internal/work/poll"
  @worker_complete "/internal/work/complete"
  @worker_accept "/internal/work/accept"
  @worker_reject "/internal/work/reject"

  setup context do
    assert {:ok, _} = Jobs.sync_capacity()

    worker_token = "worker-test-#{System.unique_integer([:positive])}"
    previous = Application.get_env(:omashiki, :worker_token)

    Application.put_env(:omashiki, :worker_token, worker_token)

    on_exit(fn ->
      if previous do
        Application.put_env(:omashiki, :worker_token, previous)
      else
        Application.delete_env(:omashiki, :worker_token)
      end
    end)

    ctx =
      if context[:unauthenticated] do
        user = user_fixture()
        {token, plaintext} = api_token_fixture(user)
        [user: user, token: token, api_plaintext: plaintext]
      else
        []
      end

    {:ok, Keyword.merge(ctx, worker_token: worker_token)}
  end

  defp worker_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp without_capacity(%JobAttempt{} = attempt) do
    reserve_fixture_capacity!()

    Repo.update_all(from(a in JobAttempt, where: a.id == ^attempt.id),
      set: [machine_id: Config.current_machine().name]
    )

    %{attempt | machine_id: Config.current_machine().name}
  end

  defp reserve_fixture_capacity! do
    machine = Config.current_machine().name

    case Repo.update_all(
           from(c in ExecutionCapacity,
             where: c.machine_id == ^machine and c.active < c.capacity
           ),
           inc: [active: 1]
         ) do
      {1, _} -> :ok
      {0, _} -> flunk("no free capacity row for #{machine}")
    end
  end

  describe "authentication" do
    @tag :unauthenticated
    test "returns 401 without a worker token", %{conn: conn} do
      conn = post(conn, @worker_poll, %{machine_id: "box-a", free_slots: 1})
      assert %{"error" => %{"code" => "missing_token"}} = json_response(conn, 401)
    end

    @tag :unauthenticated
    test "returns 403 with the wrong worker token", %{conn: conn} do
      conn = worker_conn(conn, "not-the-worker-token")
      conn = post(conn, @worker_poll, %{machine_id: "box-a", free_slots: 1})
      assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 403)
    end

    @tag :unauthenticated
    test "rejects operator API tokens on worker routes", %{conn: conn, api_plaintext: api} do
      conn = worker_conn(conn, api)
      conn = post(conn, @worker_poll, %{machine_id: "box-a", free_slots: 1})
      assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 403)
    end

    @tag :unauthenticated
    test "returns 403 when worker token is unset", %{conn: conn} do
      Application.delete_env(:omashiki, :worker_token)

      conn = worker_conn(conn, "anything")
      conn = post(conn, @worker_poll, %{machine_id: "box-a", free_slots: 1})
      assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 403)
    end

    @tag :unauthenticated
    test "returns 401 without a worker token on accept and reject", %{conn: conn} do
      conn = post(conn, @worker_accept, %{attempt_id: Ecto.UUID.generate(), lease_token: "t"})
      assert %{"error" => %{"code" => "missing_token"}} = json_response(conn, 401)

      conn = build_conn()
      conn = post(conn, @worker_reject, %{attempt_id: Ecto.UUID.generate(), lease_token: "t"})
      assert %{"error" => %{"code" => "missing_token"}} = json_response(conn, 401)
    end
  end

  describe "poll and complete" do
    @tag :unauthenticated
    test "poll with no queued job returns a null offer", %{conn: conn, worker_token: token} do
      conn = worker_conn(conn, token)
      conn = post(conn, @worker_poll, %{machine_id: "box-a", free_slots: 1})
      assert %{"offer" => nil} = json_response(conn, 200)
    end

    @tag :unauthenticated
    test "poll claims a files job with payload and no repository snapshot", %{
      conn: conn,
      worker_token: token,
      user: user,
      token: token_record,
      api_plaintext: api_plaintext
    } do
      payload = %{"instruction" => "edit files", "context" => %{"path" => "src"}}

      {job, _attempt} =
        job_fixture(user, token_record, %{
          status: "queued",
          payload: payload,
          repository: nil,
          admitted_environment: %{"name" => "files-env", "sink" => "files"},
          admitted_repository: nil,
          admitted_repository_digest: nil
        })

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_poll, %{machine_id: "box-a", free_slots: 1})

      assert %{
               "offer" => %{
                 "job_id" => job_id,
                 "sink" => "files",
                 "payload" => ^payload,
                 "admitted_repository" => nil,
                 "attempt_id" => attempt_id,
                 "lease_token" => lease_token
               }
             } = json_response(conn, 200)

      assert job_id == job.id

      body = "artifact-bytes"
      digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      conn =
        build_conn()
        |> worker_conn(token)
        |> put_req_header("x-omashiki-digest", digest)
        |> put_req_header("content-type", "application/octet-stream")
        |> put(~p"/internal/work/blobs/#{job_id}", body)

      assert %{"path" => blob_path, "digest" => ^digest} = json_response(conn, 201)
      assert File.exists?(blob_path)

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_complete, %{
          "attempt_id" => attempt_id,
          "lease_token" => lease_token,
          "complete" => %{
            "kind" => "files",
            "changed_bytes" => byte_size(body),
            "blob_digest" => digest
          }
        })

      assert %{"ok" => true} = json_response(conn, 200)

      reloaded = Repo.get!(Job, job.id)
      assert reloaded.status == "succeeded"
      assert reloaded.terminal_result["sink"] == "files"
      assert reloaded.terminal_result["blob_path"] == blob_path

      conn = put_req_header(build_conn(), "authorization", "Bearer #{api_plaintext}")
      conn = get(conn, ~p"/api/v1/jobs/#{job.id}/result")
      assert %{"data" => %{"status" => "succeeded", "result" => %{"sink" => "files"}}} =
               json_response(conn, 200)
    end

    test "completes a none sink job", %{user: user, token: token_record} do
      {job, attempt} =
        job_fixture(user, token_record, %{
          status: "provisioning",
          admitted_environment: %{"name" => "none-env", "sink" => "none"}
        })

      attempt = without_capacity(attempt)

      assert {:ok, _} =
               Inbox.complete(attempt.id, attempt.lease_token, %{
                 "kind" => "none",
                 "changed_bytes" => 0
               })

      reloaded = Repo.get!(Job, job.id)
      assert reloaded.status == "succeeded"
      assert reloaded.terminal_result == %{
               "sink" => "none",
               "changed_bytes" => 0,
               "job_id" => job.id
             }
    end

    test "completes an error sink job as failed", %{user: user, token: token_record} do
      {job, attempt} =
        job_fixture(user, token_record, %{
          status: "provisioning"
        })

      attempt = without_capacity(attempt)

      assert {:ok, _} =
               Inbox.complete(attempt.id, attempt.lease_token, %{
                 "kind" => "error",
                 "code" => "runner_failed",
                 "message" => "container exited",
                 "details" => %{"exit" => 1}
               })

      reloaded = Repo.get!(Job, job.id)
      assert reloaded.status == "failed"
      assert reloaded.terminal_error["code"] == "runner_failed"
    end

    test "completes a git sink job with branch and shas", %{user: user, token: token_record} do
      {job, attempt} =
        job_fixture(user, token_record, %{
          status: "provisioning",
          admitted_environment: %{"name" => "git-env", "sink" => "git"}
        })

      attempt = without_capacity(attempt)

      base = String.duplicate("a", 40)
      head = String.duplicate("b", 40)

      assert {:ok, _} =
               Inbox.complete(attempt.id, attempt.lease_token, %{
                 "kind" => "git",
                 "remote" => "origin",
                 "branch" => "omashiki/test",
                 "base_sha" => base,
                 "head_sha" => head
               })

      reloaded = Repo.get!(Job, job.id)
      assert reloaded.status == "succeeded"
      assert reloaded.terminal_result["branch"] == "omashiki/test"
    end

    test "heartbeat returns cancel when the job was cancelled", %{user: user, token: token_record} do
      {job, attempt} =
        job_fixture(user, token_record, %{
          status: "provisioning"
        })

      attempt = without_capacity(attempt)

      assert {:ok, _} = Jobs.cancel(job)

      assert {:ok, :cancel} = Inbox.heartbeat(attempt.id, attempt.lease_token)
    end

    @tag :unauthenticated
    test "accept returns 200 after poll", %{
      conn: conn,
      worker_token: token,
      user: user,
      token: token_record
    } do
      {job, _attempt} = job_fixture(user, token_record, %{status: "queued"})

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_poll, %{machine_id: "box-a", free_slots: 1})

      assert %{"offer" => %{"attempt_id" => attempt_id, "lease_token" => lease_token}} =

               json_response(conn, 200)

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_accept, %{"attempt_id" => attempt_id, "lease_token" => lease_token})

      assert %{"ok" => true} = json_response(conn, 200)

      reloaded = Repo.get!(JobAttempt, attempt_id)
      assert reloaded.status == "provisioning"
      assert reloaded.job_id == job.id
    end

    @tag :unauthenticated
    test "reject after poll returns job to queued", %{
      worker_token: token,
      user: user,
      token: token_record
    } do
      job = job_fixture(user, token_record, %{status: "queued"}) |> elem(0)

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_poll, %{machine_id: "box-a", free_slots: 1})

      assert %{"offer" => %{"attempt_id" => attempt_id, "lease_token" => lease_token}} =
               json_response(conn, 200)

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_reject, %{"attempt_id" => attempt_id, "lease_token" => lease_token})

      assert %{"ok" => true} = json_response(conn, 200)

      reloaded_job = Repo.get!(Job, job.id)
      reloaded_attempt = Repo.get!(JobAttempt, attempt_id)
      assert reloaded_job.status == "queued"
      assert reloaded_job.started_at == nil
      assert reloaded_attempt.status == "queued"

      conn =
        build_conn()
        |> worker_conn(token)
        |> post(@worker_poll, %{machine_id: "box-a", free_slots: 1})

      assert %{"offer" => %{"job_id" => job_id, "attempt_id" => ^attempt_id}} =
               json_response(conn, 200)

      assert job_id == job.id
    end
  end
end
