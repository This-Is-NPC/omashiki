defmodule OmashikiWeb.Api.JobsControllerTest do
  use OmashikiWeb.ConnCase, async: false

  @moduletag :api

  alias Omashiki.Config
  alias Omashiki.Jobs.{Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  import Ecto.Query

  @api_spec OmashikiWeb.ApiSpec.spec()

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-api-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
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
        "environments" => %{
          "safe" => %{
            "runtime" => "docker.runc.debian",
            "sink" => "git",
            "packages" => [],
            "preset" => "opencode",
            "executables" => ["git"],
            "credentials" => [],
            "capabilities" => [],
            "caches" => [],
            "mounts" => [],
            "pre_steps" => [],
            "post_steps" => [],
            "policy" => %{"mode" => "off"},
            "network" => "none",
            "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32},
            "timeout_ms" => 1_000
          }
        },
        "limits" => %{}
      },
      path: Path.join(root, "omashiki.toml")
    )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  @tag :unauthenticated
  test "requires a bearer token with problem+json", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn() |> get("/api/v1/jobs")

    assert conn.status == 401
    body = json_response(conn, 401)
    assert body["code"] == "missing_token"
    assert_schema(body, "Problem", @api_spec)
  end

  test "submits idempotently and returns the same job without duplicate effects", %{
    conn: conn,
    token_plaintext: plaintext
  } do
    request = request()

    first = post(conn, "/api/v1/jobs", request)
    second = post(build_conn_with_auth(plaintext), "/api/v1/jobs", request)

    assert first.status == 202
    assert second.status == 202
    assert json_response(first, 202)["data"]["id"] == json_response(second, 202)["data"]["id"]
    assert_schema(json_response(first, 202), "JobResponse", @api_spec)
    assert Repo.aggregate(Job, :count, :id) == 1
    assert Repo.aggregate(JobEvent, :count, :event_id) == 1
  end

  test "a different token cannot inspect or cancel another token's job", %{
    token: token,
    user: user
  } do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())
    {_other, plaintext} = api_token_fixture(user)

    conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")

    forbidden = get(conn, "/api/v1/jobs/#{job.id}")
    assert forbidden.status == 403
    assert json_response(forbidden, 403)["code"] == "forbidden"
    assert post(conn, "/api/v1/jobs/#{job.id}/cancel", %{}).status == 403
  end

  test "the local operator can inspect jobs from every owned token", %{user: user, token: token} do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())
    {_other, _plaintext} = api_token_fixture(user)

    conn =
      json_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id})

    shown = get(conn, "/api/v1/jobs/#{job.id}")
    assert shown.status == 200
    assert_schema(json_response(shown, 200), "JobResponse", @api_spec)
  end

  test "rejects an unknown status filter", %{conn: conn} do
    conn = get(conn, "/api/v1/jobs?status=not-a-status")
    assert conn.status == 400
    assert json_response(conn, 400)["code"] == "invalid_status"
  end

  test "rejects a batch over the atomic admission limit without writes", %{conn: conn} do
    jobs = Enum.map(1..101, fn n -> batch_job("job-#{n}") end)

    response =
      post(conn, "/api/v1/jobs/batch", %{correlation_id: "batch", jobs: jobs})

    assert response.status == 413
    assert json_response(response, 413)["code"] == "batch_too_large"
    assert Repo.aggregate(Job, :count, :id) == 0
  end

  test "cancellation is idempotent and retry returns 202", %{
    conn: conn,
    token: token,
    token_plaintext: plaintext
  } do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())

    cancelled = post(conn, "/api/v1/jobs/#{job.id}/cancel", %{})
    repeated = post(build_conn_with_auth(plaintext), "/api/v1/jobs/#{job.id}/cancel", %{})
    retried = post(build_conn_with_auth(plaintext), "/api/v1/jobs/#{job.id}/retry", %{})

    assert cancelled.status == 200
    assert json_response(cancelled, 200)["data"]["status"] == "cancelled"
    assert repeated.status == 200
    assert retried.status == 202
    assert json_response(retried, 202)["data"]["attempt"] == 2
  end

  test "a read-only token cannot submit", %{user: user} do
    {_token, plaintext} =
      api_token_fixture(user, %{
        scopes: ["read"],
        allowed_environments: ["*"],
        max_active_jobs: 10,
        ttl_days: 7
      })

    conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
    listed = get(conn, "/api/v1/jobs")
    assert listed.status == 200

    submitted = post(conn, "/api/v1/jobs", request())
    assert submitted.status == 403
    assert json_response(submitted, 403)["code"] == "insufficient_scope"
  end

  test "admission outside allowed environments is refused", %{user: user} do
    {_token, plaintext} =
      api_token_fixture(user, %{
        scopes: ["read", "submit", "cancel"],
        allowed_environments: ["other"],
        max_active_jobs: 10,
        ttl_days: 7
      })

    conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
    response = post(conn, "/api/v1/jobs", request())
    assert response.status == 422
    assert json_response(response, 422)["code"] == "environment_not_allowed"
    assert Repo.aggregate(Job, :count, :id) == 0
  end

  test "the third active job with max_active_jobs 2 is 429", %{user: user} do
    {_token, plaintext} =
      api_token_fixture(user, %{
        scopes: ["read", "submit", "cancel"],
        allowed_environments: ["*"],
        max_active_jobs: 2,
        ttl_days: 7
      })

    conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
    assert post(conn, "/api/v1/jobs", request(%{"idempotency_key" => "a"})).status == 202
    assert post(conn, "/api/v1/jobs", request(%{"idempotency_key" => "b"})).status == 202

    third = post(conn, "/api/v1/jobs", request(%{"idempotency_key" => "c"}))
    assert third.status == 429
    assert json_response(third, 429)["code"] == "max_active_jobs"
  end

  test "retry is refused when max_active_jobs is already held", %{user: user} do
    {token, plaintext} =
      api_token_fixture(user, %{
        scopes: ["read", "submit", "cancel"],
        allowed_environments: ["*"],
        max_active_jobs: 1,
        ttl_days: 7
      })

    {:ok, cancelled} =
      Omashiki.Jobs.Admission.admit(token, request(%{"idempotency_key" => "retry-me"}))

    {:ok, _} = Omashiki.Jobs.cancel(cancelled)

    {:ok, _active} =
      Omashiki.Jobs.Admission.admit(token, request(%{"idempotency_key" => "held"}))

    conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
    retried = post(conn, "/api/v1/jobs/#{cancelled.id}/retry", %{})
    assert retried.status == 429
    assert json_response(retried, 429)["code"] == "max_active_jobs"
  end

  test "invalid since is 422", %{conn: conn} do
    response = get(conn, "/api/v1/jobs?since=not-a-date")
    assert response.status == 422
    body = json_response(response, 422)
    assert body["code"] == "invalid_request"
    assert_schema(body, "Problem", @api_spec)
  end

  test "authenticated responses advertise token expiry", %{conn: conn} do
    response = get(conn, "/api/v1/jobs")
    assert response.status == 200
    assert [expires] = get_resp_header(response, "x-token-expires-at")
    assert {:ok, _, _} = DateTime.from_iso8601(expires)
    assert_schema(json_response(response, 200), "JobListResponse", @api_spec)
  end

  test "submit audit stores the request id once", %{conn: conn} do
    request = request()
    first = post(conn, "/api/v1/jobs", request)
    second = post(conn, "/api/v1/jobs", request)

    assert first.status == 202
    assert second.status == 202

    events =
      Omashiki.Repo.all(from(e in Omashiki.ApiTokens.AuditEvent, where: e.action == "submit"))

    assert length(events) == 1
    assert is_binary(hd(events).request_id)
  end

  test "terminal result matches JobResultResponse", %{conn: conn, user: user, token: token} do
    {job, attempt} =
      Omashiki.JobFixtures.job_fixture(user, token, %{status: "succeeded"})

    changes = %{
      "files_changed" => 1,
      "insertions" => 2,
      "deletions" => 0,
      "files" => [%{"path" => "hello.py", "insertions" => 2, "deletions" => 0}]
    }

    attempt
    |> JobAttempt.changeset(%{
      summary: "added hello.py",
      changes: changes,
      compare_url: "https://github.com/acme/omashiki/compare/1...2"
    })
    |> Repo.update!()

    response = get(conn, "/api/v1/jobs/#{job.id}/result")
    assert response.status == 200
    body = json_response(response, 200)
    assert body["data"]["summary"] == "added hello.py"
    assert [%{"path" => "hello.py"}] = body["data"]["changes"]["files"]
    assert_schema(body, "JobResultResponse", @api_spec)
  end

  test "an expired token is 401", %{user: user} do
    expires = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    {_token, plaintext} =
      api_token_fixture(user, %{
        scopes: ["read"],
        allowed_environments: ["*"],
        max_active_jobs: 10,
        expires_at: expires
      })

    conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
    response = get(conn, "/api/v1/jobs")
    assert response.status == 401
    assert json_response(response, 401)["code"] == "token_expired"
  end

  test "cursor pages 250 jobs without duplicates", %{conn: conn, user: user, token: token} do
    for n <- 1..250 do
      Omashiki.JobFixtures.job_fixture(user, token, %{
        idempotency_key: "page-#{n}",
        correlation_id: "page"
      })
    end

    {ids, cursor} = collect_ids(conn, nil, [])
    assert length(ids) == 250
    assert length(Enum.uniq(ids)) == 250
    assert cursor == nil
  end

  test "result without wait is 409 while the job is running", %{conn: conn, token: token} do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())
    response = get(conn, "/api/v1/jobs/#{job.id}/result")
    assert response.status == 409
    assert json_response(response, 409)["code"] == "result_not_ready"
  end

  test "result wait times out with 202", %{conn: conn, token: token} do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())
    response = get(conn, "/api/v1/jobs/#{job.id}/result?wait=1")
    assert response.status == 202
    assert get_resp_header(response, "retry-after") != []
  end

  test "discovery is read-only and does not expose repository paths", %{
    conn: conn,
    token_plaintext: plaintext,
    root: root
  } do
    repositories = get(conn, "/api/v1/repositories")
    environments = get(build_conn_with_auth(plaintext), "/api/v1/environments")

    assert repositories.status == 200
    assert get_in(json_response(repositories, 200), ["data", Access.at(0), "name"]) == "app"
    refute repositories.resp_body =~ root
    assert environments.status == 200
    refute environments.resp_body =~ "credentials"
    environment = json_response(environments, 200)["data"] |> List.first()
    assert environment["runtime"] == "docker.runc.debian"
    assert environment["handler"] == "runc"
    assert environment["backend"] == "docker"
    assert environment["distribution"] == "debian"
    assert environment["image"] == "omashiki/agent:latest"
    assert_schema(json_response(repositories, 200), "RepositoryListResponse", @api_spec)
    assert_schema(json_response(environments, 200), "EnvironmentListResponse", @api_spec)
  end

  test "redeliver requeues a failed webhook and refuses a delivered one", %{
    conn: conn,
    user: user,
    token: token
  } do
    alias Omashiki.Jobs.{WebhookDelivery, Webhooks}

    {:ok, _} =
      Webhooks.configure(token, %{
        destination: "https://client.test/hook",
        secret: "client-secret"
      })

    {job, attempt} =
      Omashiki.JobFixtures.job_fixture(user, token, %{status: "provisioning"})

    assert {:ok, _} = Omashiki.Jobs.sync_capacity()
    machine = Omashiki.Config.current_machine().name

    Repo.update_all(
      from(c in Omashiki.Jobs.ExecutionCapacity, where: c.machine_id == ^machine),
      inc: [active: 1]
    )

    Repo.update_all(from(a in JobAttempt, where: a.id == ^attempt.id), set: [machine_id: machine])
    attempt = %{attempt | machine_id: machine}

    {:ok, _} =
      Omashiki.Jobs.complete(attempt, attempt.lease_token, "succeeded", %{
        result: %{"ok" => true},
        branch: "jobs/webhook",
        base_sha: String.duplicate("a", 40),
        head_sha: String.duplicate("b", 40),
        worktree_clean: true
      })

    delivery = Repo.one!(from(d in WebhookDelivery, limit: 1))

    delivery
    |> WebhookDelivery.changeset(%{status: "failed"})
    |> Repo.update!()

    requeued =
      post(conn, "/api/v1/jobs/#{job.id}/webhook-deliveries/#{delivery.id}/redeliver", %{})

    assert requeued.status == 202
    assert_schema(json_response(requeued, 202), "WebhookDeliveryListResponse", @api_spec)

    delivery
    |> Repo.reload()
    |> WebhookDelivery.changeset(%{
      status: "delivered",
      delivered_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()

    refused =
      post(conn, "/api/v1/jobs/#{job.id}/webhook-deliveries/#{delivery.id}/redeliver", %{})

    assert refused.status == 409
    assert json_response(refused, 409)["code"] == "already_delivered"
  end

  defp collect_ids(conn, cursor, acc) do
    path = if cursor, do: "/api/v1/jobs?cursor=#{cursor}", else: "/api/v1/jobs"
    response = get(conn, path)
    assert response.status == 200
    body = json_response(response, 200)
    ids = acc ++ Enum.map(body["data"], & &1["id"])

    case body["next_cursor"] do
      nil -> {ids, nil}
      next -> collect_ids(conn, next, ids)
    end
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "idempotency_key" => "request-#{System.unique_integer([:positive])}",
        "correlation_id" => "correlation-1",
        "repo" => "app",
        "environment" => "safe",
        "payload" => %{"instruction" => "run", "branch" => "feat-test"},
        "priority" => 1
      },
      overrides
    )
  end

  defp batch_job(ref) do
    %{
      "ref" => ref,
      "idempotency_key" => "batch-#{ref}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{
        "instruction" => "run",
        "context" => %{"ref" => ref},
        "branch" => "feat-#{ref}"
      },
      "priority" => 0
    }
  end

  defp build_conn_with_auth(plaintext) do
    json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
  end
end
