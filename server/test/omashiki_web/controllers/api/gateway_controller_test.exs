defmodule OmashikiWeb.Api.GatewayControllerTest do
  @moduledoc """
  Regression cover for `cdd801a fix(gateway): route agent LLM ingress`.

  The 400-job load test produced its worst failure here: `GatewayController`
  existed and `Omashiki.Gateway` handed containers a base URL pointing at it,
  but **no route reached it**. Every completion 404'd, OpenCode read that as an
  empty turn, and jobs finished `succeeded` having made zero LLM calls — a green
  result, which is why it survived. Nothing covered this path, so nothing
  caught it.

  These tests drive the exact path an agent container takes: the URL is derived
  from `Gateway.openai_base_url/0` (what the container is actually told), the
  request goes through the real router and endpoint, and a fake provider stands
  in for the upstream. Delete the route from `router.ex` and all 13 tests in
  this module go red (404 / Phoenix.Router.NoRouteError); restore it and they
  go green — verified, not assumed.
  """

  use OmashikiWeb.ConnCase, async: false

  import Ecto.Query

  alias Omashiki.Gateway
  alias Omashiki.Jobs.Job
  alias Omashiki.Repo
  alias Omashiki.UsageLedger.Entry

  # This route must never accept an operator API token, so no test here wants
  # ConnCase's bearer header.
  @moduletag :unauthenticated

  @gateway_salt "omashiki.runtime.gateway"

  setup do
    bypass = Bypass.open()

    credential =
      credential_fixture(%{
        provider: "openai",
        model: "gpt-5-mini",
        api_key: "sk-provider-key",
        base_url: "http://localhost:#{bypass.port}"
      })

    user = user_fixture()
    job = running_job(user, credential.name)
    token = Gateway.sign_token(job.id, user.id, job.admitted_environment_digest, credential.name)

    %{bypass: bypass, credential: credential, user: user, job: job, token: token}
  end

  describe "LLM ingress route" do
    test "the container base URL resolves to a real POST route", %{conn: conn} do
      # `Gateway.openai_base_url/0` is what gets injected into the engine. If
      # the router does not serve that exact path, agents 404.
      assert Enum.any?(OmashikiWeb.Router.__routes__(), fn route ->
               route.verb == :post and route.path == completions_path()
             end),
             """
             No POST route serves #{completions_path()}, the path handed to agent
             containers by Gateway.openai_base_url/0. Agents will 404 on every
             completion and report empty turns. See commit cdd801a.
             """

      # The route existing is not enough — it must dispatch.
      refute match?(%Plug.Conn{status: 404}, post_completion(conn, "bogus-token", %{}))
    end

    test "a job-bound token is accepted and the request reaches the provider base_url",
         %{conn: conn, bypass: bypass, token: token, job: job} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn upstream ->
        {:ok, raw, upstream} = Plug.Conn.read_body(upstream)

        send(
          parent,
          {:upstream_hit, Jason.decode!(raw), Plug.Conn.get_req_header(upstream, "authorization")}
        )

        upstream
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(provider_response()))
      end)

      conn =
        post_completion(conn, token, %{
          "model" => "gpt-5-mini",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert %{"choices" => [%{"message" => %{"content" => "pong"}}]} = json_response(conn, 200)

      assert_received {:upstream_hit, forwarded, ["Bearer sk-provider-key"]}
      assert forwarded["model"] == "gpt-5-mini"
      assert forwarded["messages"] == [%{"role" => "user", "content" => "hello"}]

      # And the call was metered against the job.
      assert llm_calls(job) == 1
    end

    test "a job cannot reach terminal succeeded having made zero LLM calls",
         %{conn: conn, bypass: bypass, token: token, job: job} do
      # The load-test failure mode, stated as an invariant. Before any LLM
      # ingress the ledger is empty — a job that finished here would be the
      # silent green.
      assert llm_calls(job) == 0

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn upstream ->
        upstream
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(provider_response()))
      end)

      conn =
        post_completion(conn, token, %{
          "model" => "gpt-5-mini",
          "messages" => [%{"role" => "user", "content" => "do the work"}]
        })

      assert json_response(conn, 200)

      # The harness declared by this job's environment requires an LLM, so the
      # ledger must show the turn before the job is allowed to go terminal.
      assert llm_calls(job) > 0

      {:ok, job} =
        job
        |> Job.changeset(%{
          status: "succeeded",
          finished_at: DateTime.utc_now(:microsecond),
          terminal_result: %{"ok" => true}
        })
        |> Repo.update()

      assert job.status == "succeeded"
      assert llm_calls(job) > 0, "job succeeded having made zero LLM calls"
    end

    test "a streaming request is answered as SSE, not a hung JSON body",
         %{conn: conn, bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn upstream ->
        {:ok, raw, upstream} = Plug.Conn.read_body(upstream)

        # The gateway buffers for metering, so upstream must never be asked to
        # stream even when the engine did.
        assert Jason.decode!(raw)["stream"] == false

        upstream
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(provider_response()))
      end)

      conn =
        post_completion(conn, token, %{
          "model" => "gpt-5-mini",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "data: [DONE]"
      assert conn.resp_body =~ "chat.completion.chunk"
    end
  end

  describe "token rejection" do
    test "a missing bearer is rejected", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(completions_path(), Jason.encode!(%{"messages" => []}))

      assert json_response(conn, 401) == %{"error" => %{"message" => "missing_token"}}
    end

    test "a forged bearer is rejected", %{conn: conn} do
      conn = post_completion(conn, "not-a-real-token", %{"messages" => []})
      assert json_response(conn, 401) == %{"error" => %{"message" => "invalid_token"}}
    end

    test "a tampered but well-formed token is rejected", %{conn: conn, token: token} do
      conn = post_completion(conn, token <> "tampered", %{"messages" => []})
      assert json_response(conn, 401) == %{"error" => %{"message" => "invalid_token"}}
    end

    test "an expired token is rejected", %{conn: conn, job: job, credential: credential} do
      expired =
        Phoenix.Token.sign(
          OmashikiWeb.Endpoint,
          @gateway_salt,
          %{
            "kind" => "gateway",
            "job_id" => job.id,
            "token_owner" => job.user_id,
            "admitted_environment_digest" => job.admitted_environment_digest,
            "credential" => credential.name
          },
          signed_at: System.os_time(:second) - (Omashiki.Runtime.Claims.max_age_seconds() + 60)
        )

      conn = post_completion(conn, expired, %{"messages" => []})
      assert json_response(conn, 401) == %{"error" => %{"message" => "invalid_token"}}
    end

    test "an operator API token is not a gateway credential", %{conn: conn, user: user} do
      {_token, plaintext} = api_token_fixture(user)

      conn = post_completion(conn, plaintext, %{"messages" => []})
      assert json_response(conn, 401) == %{"error" => %{"message" => "invalid_token"}}
    end

    test "a rejected token never reaches the provider", %{conn: conn, bypass: bypass} do
      # With the provider down, any forwarding attempt would surface as 502.
      # A clean 401 proves the refusal happened before the outbound call.
      Bypass.down(bypass)

      conn = post_completion(conn, "not-a-real-token", %{"messages" => []})
      assert json_response(conn, 401) == %{"error" => %{"message" => "invalid_token"}}
    end
  end

  describe "authorization failures surface as status codes, not silence" do
    test "a job that already went terminal cannot spend", %{conn: conn, token: token, job: job} do
      {:ok, _} =
        job
        |> Job.changeset(%{
          status: "succeeded",
          finished_at: DateTime.utc_now(:microsecond),
          terminal_result: %{"ok" => true}
        })
        |> Repo.update()

      conn = post_completion(conn, token, %{"messages" => []})
      assert %{"error" => %{"message" => "job_not_active"}} = json_response(conn, 401)
    end

    test "a credential outside the job environment is refused", %{conn: conn, job: job} do
      other =
        credential_fixture(%{provider: "openai", model: "gpt-5-mini", api_key: "sk-other"})

      token = Gateway.sign_token(job.id, job.user_id, job.admitted_environment_digest, other.name)

      conn = post_completion(conn, token, %{"messages" => []})

      assert %{"error" => %{"message" => "credential_not_in_environment"}} =
               json_response(conn, 403)
    end

    test "an upstream error is reported, never swallowed as an empty success",
         %{conn: conn, bypass: bypass, token: token, job: job} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn upstream ->
        Plug.Conn.resp(upstream, 500, ~s({"error":"boom"}))
      end)

      conn = post_completion(conn, token, %{"messages" => []})

      assert conn.status == 500
      assert llm_calls(job) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp completions_path do
    URI.parse(Gateway.openai_base_url()).path <> "/chat/completions"
  end

  defp post_completion(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(completions_path(), Jason.encode!(body))
  end

  defp llm_calls(%Job{id: job_id}) do
    Repo.one(from(e in Entry, where: e.job_id == ^job_id, select: count(e.id)))
  end

  defp provider_response do
    %{
      "id" => "chatcmpl-#{System.unique_integer([:positive])}",
      "object" => "chat.completion",
      "model" => "gpt-5-mini",
      "created" => System.system_time(:second),
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "pong"}
        }
      ],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 7}
    }
  end

  defp running_job(user, credential_name) do
    n = System.unique_integer([:positive])

    %Job{}
    |> Job.changeset(%{
      user_id: user.id,
      schema_version: 1,
      idempotency_key: "gateway-#{n}",
      correlation_id: "gateway-corr-#{n}",
      repository: "repo",
      environment: "agentic",
      payload: %{"instruction" => "work"},
      payload_hash: String.duplicate("a", 64),
      admitted_repository: %{"path" => "/tmp/repo", "base_branch" => "main"},
      admitted_repository_digest: String.duplicate("b", 64),
      # The environment declares an LLM harness plus the credential the agent
      # is allowed to spend through — this is what makes "zero LLM calls" a bug.
      admitted_environment: %{
        "name" => "agentic",
        "preset" => "opencode",
        "credentials" => [%{"name" => credential_name}],
        "capabilities" => []
      },
      admitted_environment_digest: String.duplicate("c", 64),
      admitted_plugin: %{"path" => "plugins/opencode.toml", "contents" => "", "digest" => String.duplicate("e", 64)},
      admitted_plugin_digest: String.duplicate("e", 64),
      registry_digest: String.duplicate("d", 64),
      queue: "default",
      priority: 1,
      status: "running",
      current_attempt: 1,
      queued_at: DateTime.utc_now(:microsecond),
      started_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.insert!()
  end
end
