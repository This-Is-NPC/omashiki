defmodule Omashiki.GatewayTest do
  @moduledoc """
  The gateway core: token minting, authorization, model resolution, provider
  forwarding, fallback, and ledger truth.

  Every assertion here guards a failure that is invisible from the outside —
  a job that "succeeded" while the gateway refused, mis-routed, or failed to
  meter the call.
  """

  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.Gateway
  alias Omashiki.Gateway.CircuitBreaker
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Claims
  alias Omashiki.UsageLedger.Entry

  setup do
    CircuitBreaker.reset()

    previous_base = Application.get_env(:omashiki, :llm_gateway_base_url)
    previous_mode = Application.get_env(:omashiki, :agent_network_mode)
    previous_global = Application.get_env(:omashiki, :global_budget_tokens)

    on_exit(fn ->
      CircuitBreaker.reset()
      restore(:llm_gateway_base_url, previous_base)
      restore(:agent_network_mode, previous_mode)
      restore(:global_budget_tokens, previous_global)
    end)

    Application.delete_env(:omashiki, :global_budget_tokens)

    bypass = Bypass.open()
    name = "gw-cred-#{System.unique_integer([:positive])}"

    put_credentials!(%{
      name => %{
        "provider" => "openai",
        "model" => "gpt-5-mini",
        "api_key" => "sk-live",
        "base_url" => "http://localhost:#{bypass.port}"
      }
    })

    user = user_fixture()
    job = running_job(user, [name])

    {:ok, bypass: bypass, credential_name: name, user: user, job: job}
  end

  # ---------------------------------------------------------------------------
  # Tokens and URLs
  # ---------------------------------------------------------------------------

  describe "sign_token/4 and verify_token/1" do
    test "mints a job-bound token that verifies back to its claims",
         %{job: job, credential_name: name} do
      token = Gateway.sign_token(job.id, job.user_id, job.environment_digest, name)
      assert is_binary(token)

      assert {:ok, claims} = Gateway.verify_token(token)
      assert claims["kind"] == "gateway"
      assert claims["job_id"] == job.id
      assert claims["token_owner"] == job.user_id
      assert claims["environment_digest"] == job.environment_digest
      assert claims["credential"] == name
    end

    test "never leaks the provider key into the token", %{job: job, credential_name: name} do
      token = Gateway.sign_token(job.id, job.user_id, job.environment_digest, name)
      {:ok, claims} = Gateway.verify_token(token)

      refute Map.has_key?(claims, "api_key")
      refute claims |> Map.values() |> Enum.any?(&(&1 == "sk-live"))
    end

    test "returns nil for an unknown job", %{job: job, credential_name: name} do
      assert Gateway.sign_token(
               Ecto.UUID.generate(),
               job.user_id,
               job.environment_digest,
               name
             ) == nil
    end

    test "returns nil for a job that already went terminal",
         %{job: job, credential_name: name} do
      {:ok, job} =
        job
        |> Job.changeset(%{
          status: "succeeded",
          finished_at: DateTime.utc_now(:microsecond),
          terminal_result: %{"ok" => true}
        })
        |> Repo.update()

      assert Gateway.sign_token(job.id, job.user_id, job.environment_digest, name) == nil
    end

    test "rejects a garbage token" do
      assert {:error, :invalid} = Gateway.verify_token("not-a-token")
    end

    test "rejects an expired token", %{job: job, credential_name: name} do
      expired =
        Phoenix.Token.sign(
          OmashikiWeb.Endpoint,
          "omashiki.runtime.gateway",
          %{
            "kind" => "gateway",
            "job_id" => job.id,
            "token_owner" => job.user_id,
            "environment_digest" => job.environment_digest,
            "credential" => name
          },
          signed_at: System.os_time(:second) - (Claims.max_age_seconds() + 60)
        )

      assert {:error, :expired} = Gateway.verify_token(expired)
    end

    test "rejects a token minted for a different runtime kind", %{job: job} do
      {:ok, tools_token} = Claims.issue("tools", job)
      assert {:error, :invalid} = Gateway.verify_token(tools_token)
    end
  end

  describe "base URLs handed to containers" do
    test "an explicit configuration wins" do
      Application.put_env(:omashiki, :llm_gateway_base_url, "http://gw.internal:9000/")

      assert Gateway.base_url() == "http://gw.internal:9000/"
      assert Gateway.openai_base_url() == "http://gw.internal:9000/api/v1/gateway/v1"
    end

    test "the default targets the docker host bridge on the endpoint port" do
      Application.delete_env(:omashiki, :llm_gateway_base_url)
      Application.delete_env(:omashiki, :agent_network_mode)

      assert Gateway.base_url() == "http://host.docker.internal:4002"
    end

    test "host networking targets the loopback instead" do
      Application.delete_env(:omashiki, :llm_gateway_base_url)
      Application.put_env(:omashiki, :agent_network_mode, "host")

      assert Gateway.base_url() == "http://127.0.0.1:4002"
    end

    test "the OpenAI-compatible suffix is appended exactly once" do
      Application.put_env(:omashiki, :llm_gateway_base_url, "http://gw.internal:9000")
      assert Gateway.openai_base_url() == "http://gw.internal:9000/api/v1/gateway/v1"
    end
  end

  # ---------------------------------------------------------------------------
  # chat_completions/2
  # ---------------------------------------------------------------------------

  describe "chat_completions/2 forwarding" do
    test "reaches the configured base_url and meters the call",
         %{bypass: bypass, job: job, credential_name: name} do
      expect_provider(bypass, response("chatcmpl-1", 120, 34))

      assert {:ok, response} =
               Gateway.chat_completions(
                 %{
                   "model" => "gpt-5-mini",
                   "messages" => [%{"role" => "user", "content" => "hi"}]
                 },
                 claims(job, name)
               )

      assert response["id"] == "chatcmpl-1"

      assert [entry] = ledger(job)
      assert entry.provider == "openai"
      assert entry.model == "gpt-5-mini"
      assert entry.input_tokens == 120
      assert entry.output_tokens == 34
      assert entry.turn == 1
      assert entry.provider_request_id == "chatcmpl-1"
      assert entry.request_id == "gateway:chatcmpl-1"

      # DEFECT (reported, not fixed here): `UsageLedger` documents gateway rows
      # as `source: "gateway"` and `Entry` validates that value, but
      # `Gateway.record_usage/4` never sets it. Any consumer that separates
      # gateway spend from engine-reported spend by `source` silently misses
      # every gateway row. Flip this to `== "gateway"` when the fix lands.
      assert entry.source == nil
    end

    test "accepts atom-keyed claims from in-process callers",
         %{bypass: bypass, job: job, credential_name: name} do
      expect_provider(bypass, response("chatcmpl-atoms", 1, 1))

      assert {:ok, _} =
               Gateway.chat_completions(%{"messages" => []}, %{
                 "kind" => "gateway",
                 "job_id" => job.id,
                 "token_owner" => job.user_id,
                 "environment_digest" => job.environment_digest,
                 "credential" => name,
                 credential: name
               })

      assert [_] = ledger(job)
    end

    test "turns increment across calls", %{bypass: bypass, job: job, credential_name: name} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, response(nil, 5, 5))
      end)

      assert {:ok, _} = Gateway.chat_completions(%{"messages" => []}, claims(job, name))
      assert {:ok, _} = Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      assert [first, second] = ledger(job)
      assert first.turn == 1
      assert second.turn == 2

      # No provider id: the request_id falls back to a stable job/turn identity
      # so a retry collides instead of double-billing.
      assert first.request_id == "gateway:job:#{job.id}:turn:1"
      assert second.request_id == "gateway:job:#{job.id}:turn:2"
    end

    test "a repeated provider request id cannot double-bill",
         %{bypass: bypass, job: job, credential_name: name} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, response("chatcmpl-fixed", 10, 10))
      end)

      assert {:ok, _} = Gateway.chat_completions(%{"messages" => []}, claims(job, name))
      assert {:ok, _} = Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      assert [entry] = ledger(job)
      assert entry.request_id == "gateway:chatcmpl-fixed"
    end

    test "an unreported cache column is recorded as unknown, never as zero",
         %{bypass: bypass, job: job, credential_name: name} do
      expect_provider(bypass, response("chatcmpl-nocache", 10, 10))

      assert {:ok, _} = Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      assert [entry] = ledger(job)
      assert entry.cached_input_tokens == nil
      assert entry.cache_write_tokens == nil
      assert entry.reasoning_tokens == nil
    end
  end

  describe "model resolution" do
    test "an engine-side gateway/ prefix is stripped before forwarding",
         %{bypass: bypass, job: job, credential_name: name} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upstream, Jason.decode!(raw)})
        json(conn, response("chatcmpl-prefix", 1, 1))
      end)

      assert {:ok, _} =
               Gateway.chat_completions(
                 %{"model" => "gateway/gpt-5-mini", "messages" => []},
                 claims(job, name)
               )

      assert_received {:upstream, %{"model" => "gpt-5-mini"}}
      assert [%{model: "gpt-5-mini"}] = ledger(job)
    end

    test "a credential alias rewrites the requested model", %{bypass: bypass, user: user} do
      name = "aliased-#{System.unique_integer([:positive])}"

      put_credentials!(%{
        name => %{
          "provider" => "openai",
          "model" => "gpt-5-mini",
          "api_key" => "sk-live",
          "base_url" => "http://localhost:#{bypass.port}",
          "model_aliases" => %{"house-model" => "gpt-5-nano"}
        }
      })

      job = running_job(user, [name])
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upstream, Jason.decode!(raw)})
        json(conn, response("chatcmpl-alias", 1, 1))
      end)

      assert {:ok, _} =
               Gateway.chat_completions(
                 %{"model" => "provider/house-model", "messages" => []},
                 claims(job, name)
               )

      assert_received {:upstream, %{"model" => "gpt-5-nano"}}
      assert [%{model: "gpt-5-nano"}] = ledger(job)
    end

    test "a request without a model falls back to the credential default",
         %{bypass: bypass, job: job, credential_name: name} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upstream, Jason.decode!(raw)})
        json(conn, response("chatcmpl-default", 1, 1))
      end)

      assert {:ok, _} = Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      assert_received {:upstream, %{"model" => "gpt-5-mini"}}
    end
  end

  describe "authorization refusals" do
    test "a job that is no longer active gets 401",
         %{bypass: bypass, job: job, credential_name: name} do
      Bypass.down(bypass)

      {:ok, _} =
        job
        |> Job.changeset(%{
          status: "succeeded",
          finished_at: DateTime.utc_now(:microsecond),
          terminal_result: %{"ok" => true}
        })
        |> Repo.update()

      assert {:error, %{status: 401, error: %{message: "job_not_active", type: "auth"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, name))
    end

    test "a deleted job gets 401", %{job: job, credential_name: name} do
      claims = claims(job, name)
      Repo.delete!(job)

      assert {:error, %{status: 401, error: %{message: "job_missing"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims)
    end

    test "a claim naming another owner gets 403", %{job: job, credential_name: name} do
      claims = claims(job, name) |> Map.put("token_owner", Ecto.UUID.generate())

      assert {:error, %{status: 403, error: %{message: "owner_mismatch"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims)
    end

    test "a stale environment digest gets 403", %{job: job, credential_name: name} do
      claims = claims(job, name) |> Map.put("environment_digest", String.duplicate("f", 64))

      assert {:error, %{status: 403, error: %{message: "environment_changed"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims)
    end

    test "a credential the environment never declared gets 403", %{job: job} do
      other = "undeclared-#{System.unique_integer([:positive])}"

      put_credentials!(%{
        other => %{"provider" => "openai", "model" => "gpt-5-mini", "api_key" => "sk-x"}
      })

      assert {:error, %{status: 403, error: %{message: "credential_not_in_environment"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, other))
    end

    test "a credential that vanished from config gets 401", %{user: user} do
      name = "vanishing-#{System.unique_integer([:positive])}"

      put_credentials!(%{
        name => %{"provider" => "openai", "model" => "gpt-5-mini", "api_key" => "sk-x"}
      })

      job = running_job(user, [name])
      # Operator removed the credential from omashiki.toml between provisioning
      # and the turn.
      Omashiki.Fixtures.load_default_config!()

      assert {:error, %{status: 401, error: %{message: "credential_missing"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, name))
    end
  end

  describe "budget enforcement at the gateway" do
    test "an exhausted job budget refuses the turn with 429",
         %{bypass: bypass, user: user, credential_name: name} do
      Bypass.down(bypass)
      job = running_job(user, [name], %{"budget_tokens" => 10})

      Repo.insert!(%Entry{
        request_id: "seed:#{job.id}",
        job_id: job.id,
        turn: 1,
        source: "gateway",
        input_tokens: 9,
        output_tokens: 5,
        occurred_at: DateTime.utc_now(:microsecond)
      })

      assert {:error, %{status: 429, error: %{message: "budget_exceeded", type: "budget"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      # Refused before forwarding: nothing new was billed.
      assert length(ledger(job)) == 1
    end

    test "an exhausted global budget refuses the turn",
         %{bypass: bypass, job: job, credential_name: name} do
      Bypass.down(bypass)

      Repo.insert!(%Entry{
        request_id: "seed-global:#{job.id}",
        job_id: job.id,
        turn: 1,
        source: "gateway",
        input_tokens: 500,
        output_tokens: 500,
        occurred_at: DateTime.utc_now(:microsecond)
      })

      Application.put_env(:omashiki, :global_budget_tokens, 1_000)

      assert {:error, %{status: 429, error: %{message: "budget_exceeded"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, name))
    end
  end

  describe "upstream failure, fallback, and the circuit breaker" do
    test "an upstream error is surfaced and nothing is billed",
         %{bypass: bypass, job: job, credential_name: name} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
      end)

      assert {:error, %{status: 500}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      assert ledger(job) == []
    end

    test "a declared fallback credential takes over when the primary fails",
         %{user: user} do
      primary_bypass = Bypass.open()
      fallback_bypass = Bypass.open()
      n = System.unique_integer([:positive])
      primary = "primary-#{n}"
      fallback = "fallback-#{n}"

      put_credentials!(%{
        fallback => %{
          "provider" => "anthropic",
          "model" => "claude-haiku-4-5",
          "api_key" => "sk-fallback",
          "base_url" => "http://localhost:#{fallback_bypass.port}"
        },
        primary => %{
          "provider" => "openai",
          "model" => "gpt-5-mini",
          "api_key" => "sk-primary",
          "base_url" => "http://localhost:#{primary_bypass.port}",
          "fallback_chain" => [fallback]
        }
      })

      Bypass.expect(primary_bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 503, ~s({"error":"overloaded"}))
      end)

      parent = self()

      Bypass.expect_once(fallback_bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:fallback_upstream, Jason.decode!(raw)})
        json(conn, response("chatcmpl-fallback", 3, 4))
      end)

      job = running_job(user, [primary, fallback])

      assert {:ok, %{"id" => "chatcmpl-fallback"}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, primary))

      assert [entry] = ledger(job)
      assert entry.input_tokens == 3
      assert entry.output_tokens == 4

      # `provider` follows the credential that actually served the turn.
      assert entry.provider == "anthropic"

      # DEFECT (reported, not fixed here): `model` is resolved once from the
      # *primary* credential and reused for the whole fallback chain. The
      # fallback is asked for "gpt-5-mini", a model it does not serve, and the
      # ledger attributes the spend to a model that never ran. Flip these two
      # assertions to "claude-haiku-4-5" when the resolve-per-credential fix
      # lands. See Gateway.forward_with_fallback/4.
      assert_received {:fallback_upstream, %{"model" => "gpt-5-mini"}}
      assert entry.model == "gpt-5-mini"
    end

    test "a fallback the environment did not declare is not used", %{user: user} do
      primary_bypass = Bypass.open()
      fallback_bypass = Bypass.open()
      n = System.unique_integer([:positive])
      primary = "p2-#{n}"
      fallback = "f2-#{n}"

      put_credentials!(%{
        fallback => %{
          "provider" => "openai",
          "model" => "gpt-5-nano",
          "api_key" => "sk-fallback",
          "base_url" => "http://localhost:#{fallback_bypass.port}"
        },
        primary => %{
          "provider" => "openai",
          "model" => "gpt-5-mini",
          "api_key" => "sk-primary",
          "base_url" => "http://localhost:#{primary_bypass.port}",
          "fallback_chain" => [fallback]
        }
      })

      Bypass.expect(primary_bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 503, ~s({"error":"overloaded"}))
      end)

      Bypass.down(fallback_bypass)

      # Only the primary is in the job's environment snapshot.
      job = running_job(user, [primary])

      assert {:error, %{status: 503}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, primary))

      assert ledger(job) == []
    end

    test "the circuit opens after repeated failures and refuses with 503",
         %{bypass: bypass, job: job, credential_name: name} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
      end)

      for _ <- 1..3 do
        assert {:error, %{status: 500}} =
                 Gateway.chat_completions(%{"messages" => []}, claims(job, name))
      end

      assert {:error, %{status: 503, error: %{message: "circuit_open", type: "upstream"}}} =
               Gateway.chat_completions(%{"messages" => []}, claims(job, name))

      assert ledger(job) == []
    end
  end

  test "upstream_base/1 delegates to the OpenAI-compat adapter", %{credential_name: name} do
    cred = Omashiki.Credentials.get_credential(name)

    assert Gateway.upstream_base(cred) ==
             Omashiki.Gateway.Providers.OpenaiCompat.upstream_base(cred)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp restore(key, nil), do: Application.delete_env(:omashiki, key)
  defp restore(key, value), do: Application.put_env(:omashiki, key, value)

  defp put_credentials!(map), do: Omashiki.Fixtures.merge_config!(%{"credentials" => map})

  defp claims(%Job{} = job, credential_name) do
    %{
      "kind" => "gateway",
      "job_id" => job.id,
      "token_owner" => job.user_id,
      "environment_digest" => job.environment_digest,
      "credential" => credential_name
    }
  end

  defp ledger(%Job{id: job_id}) do
    Repo.all(from(e in Entry, where: e.job_id == ^job_id, order_by: [asc: e.turn]))
  end

  defp expect_provider(bypass, payload) do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", &json(&1, payload))
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  defp response(id, input, output) do
    %{
      "id" => id,
      "object" => "chat.completion",
      "model" => "gpt-5-mini",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "pong"}
        }
      ],
      "usage" => %{"prompt_tokens" => input, "completion_tokens" => output}
    }
  end

  defp running_job(user, credential_names, payload_extra \\ %{}) do
    n = System.unique_integer([:positive])

    %Job{}
    |> Job.changeset(%{
      user_id: user.id,
      schema_version: 1,
      idempotency_key: "gw-#{n}",
      correlation_id: "gw-corr-#{n}",
      repository: "repo",
      environment: "agentic",
      payload: Map.merge(%{"instruction" => "work"}, payload_extra),
      payload_hash: String.duplicate("a", 64),
      repository_snapshot: %{"path" => "/tmp/repo"},
      repository_digest: String.duplicate("b", 64),
      environment_snapshot: %{
        "name" => "agentic",
        "harness" => "opencode",
        "credentials" => Enum.map(credential_names, &%{"name" => &1})
      },
      environment_digest: String.duplicate("c", 64),
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
