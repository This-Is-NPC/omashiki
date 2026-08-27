defmodule OmashikiWeb.Api.JobsControllerTest do
  use OmashikiWeb.ConnCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs.{Job, JobEvent}
  alias Omashiki.Repo

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
        "environments" => %{
          "safe" => %{
            "isolation" => "docker",
          "image" => "omashiki/agent:latest",
          "sink" => "git",
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
  test "requires a bearer token with a stable error envelope" do
    conn = Phoenix.ConnTest.build_conn() |> get("/api/v1/jobs")

    assert conn.status == 401
    assert get_in(json_response(conn, 401), ["error", "code"]) == "missing_token"
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
    assert Repo.aggregate(Job, :count, :id) == 1
    assert Repo.aggregate(JobEvent, :count, :event_id) == 1
  end

  test "a different token cannot inspect or cancel another token's job", %{
    token: token,
    user: user
  } do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())
    {_other, plaintext} = api_token_fixture(user)

    conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")

    assert get(conn, "/api/v1/jobs/#{job.id}").status == 403
    assert post(conn, "/api/v1/jobs/#{job.id}/cancel", %{}).status == 403
  end

  test "the local operator can inspect jobs from every owned token", %{user: user, token: token} do
    {:ok, job} = Omashiki.Jobs.Admission.admit(token, request())
    {_other, _plaintext} = api_token_fixture(user)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id})

    assert get(conn, "/api/v1/jobs/#{job.id}").status == 200
  end

  test "rejects list limits outside the documented boundary", %{conn: conn} do
    assert get(conn, "/api/v1/jobs?limit=0").status == 400
    assert get(conn, "/api/v1/jobs?limit=101").status == 400
    assert get(conn, "/api/v1/jobs?status=not-a-status").status == 400
  end

  test "rejects a batch over the atomic admission limit without writes", %{conn: conn} do
    jobs = Enum.map(1..101, fn n -> batch_job("job-#{n}") end)

    response =
      post(conn, "/api/v1/jobs/batch", %{schema_version: 1, correlation_id: "batch", jobs: jobs})

    assert response.status == 413
    assert get_in(json_response(response, 413), ["error", "code"]) == "batch_too_large"
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
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "idempotency_key" => "request-#{System.unique_integer([:positive])}",
        "correlation_id" => "correlation-1",
        "repo" => "app",
        "environment" => "safe",
        "payload" => %{"instruction" => "run"},
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
      "payload" => %{"instruction" => "run", "context" => %{"ref" => ref}},
      "priority" => 0
    }
  end

  defp build_conn_with_auth(plaintext) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
  end
end
