defmodule Omashiki.Gateway.Providers.OpenaiCompatTest do
  @moduledoc """
  Request/response translation for the only shipped outbound adapter.

  The failures this guards are silent: a wrong upstream base sends spend to
  the wrong host, a leaked `stream: true` makes the upstream answer SSE that
  the buffering gateway cannot decode, and coercing an absent cache field to
  `0` invents spend that never happened (banned in Fase 0).
  """

  use ExUnit.Case, async: true

  alias Omashiki.Credentials.Credential
  alias Omashiki.Gateway.Providers.OpenaiCompat

  describe "upstream_base/1" do
    test "an explicit base_url wins and is normalised to exactly one /v1" do
      assert OpenaiCompat.upstream_base(cred(base_url: "https://llm.example.test")) ==
               "https://llm.example.test/v1"

      assert OpenaiCompat.upstream_base(cred(base_url: "https://llm.example.test/")) ==
               "https://llm.example.test/v1"

      assert OpenaiCompat.upstream_base(cred(base_url: "https://llm.example.test/v1")) ==
               "https://llm.example.test/v1"

      assert OpenaiCompat.upstream_base(cred(base_url: "https://llm.example.test/v1/")) ==
               "https://llm.example.test/v1"
    end

    test "known providers have defaults" do
      assert OpenaiCompat.upstream_base(cred(provider: "anthropic")) ==
               "https://api.anthropic.com/v1"

      assert OpenaiCompat.upstream_base(cred(provider: "openai")) == "https://api.openai.com/v1"
    end

    test "an unknown provider without base_url falls back to the OpenAI base" do
      assert OpenaiCompat.upstream_base(cred(provider: "some-vendor")) ==
               "https://api.openai.com/v1"
    end

    test "an empty base_url is not treated as configured" do
      assert OpenaiCompat.upstream_base(cred(provider: "openai", base_url: "")) ==
               "https://api.openai.com/v1"
    end
  end

  describe "extract_usage/1" do
    test "maps the OpenAI usage shape, including cache and reasoning details" do
      usage =
        OpenaiCompat.extract_usage(%{
          "id" => "chatcmpl-abc",
          "usage" => %{
            "prompt_tokens" => 120,
            "completion_tokens" => 34,
            "prompt_tokens_details" => %{"cached_tokens" => 64},
            "completion_tokens_details" => %{"reasoning_tokens" => 12}
          }
        })

      assert usage == %{
               input_tokens: 120,
               output_tokens: 34,
               cached_input_tokens: 64,
               cache_write_tokens: nil,
               reasoning_tokens: 12,
               provider_request_id: "chatcmpl-abc"
             }
    end

    test "maps the Anthropic-native usage names when a provider reports them" do
      usage =
        OpenaiCompat.extract_usage(%{
          "id" => "msg_01",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "cache_read_input_tokens" => 3,
            "cache_creation_input_tokens" => 7
          }
        })

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.cached_input_tokens == 3
      assert usage.cache_write_tokens == 7
      assert usage.provider_request_id == "msg_01"
    end

    test "absent cache and reasoning fields stay nil — absence is not zero" do
      usage =
        OpenaiCompat.extract_usage(%{
          "id" => "chatcmpl-xyz",
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
        })

      assert usage.cached_input_tokens == nil
      assert usage.cache_write_tokens == nil
      assert usage.reasoning_tokens == nil
    end

    test "a reported zero is preserved and not confused with absence" do
      usage =
        OpenaiCompat.extract_usage(%{
          "usage" => %{
            "prompt_tokens" => 1,
            "completion_tokens" => 2,
            "prompt_tokens_details" => %{"cached_tokens" => 0}
          }
        })

      # A provider that reports 0 cached tokens is telling the truth; the
      # gateway must record 0, not nil.
      assert usage.cached_input_tokens == 0
    end

    test "a response with no usage object meters nothing rather than crashing" do
      usage = OpenaiCompat.extract_usage(%{"choices" => []})

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.provider_request_id == nil
    end

    test "a non-string provider id is stringified for the ledger" do
      assert OpenaiCompat.extract_usage(%{"id" => 12_345}).provider_request_id == "12345"
    end
  end

  describe "chat_completions/3 against a provider" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
    end

    test "forwards to <base_url>/v1/chat/completions with the credential key",
         %{bypass: bypass, base_url: base_url} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:upstream, Jason.decode!(raw), Enum.into(conn.req_headers, %{})}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(ok_response()))
      end)

      credential = cred(provider: "openai", base_url: base_url, api_key: "sk-live")

      assert {:ok, %{response: response, usage: usage}} =
               OpenaiCompat.chat_completions(
                 credential,
                 %{"messages" => [%{"role" => "user", "content" => "hi"}]},
                 "gpt-5-mini"
               )

      assert response["choices"] |> hd() |> get_in(["message", "content"]) == "pong"
      assert usage.input_tokens == 11
      assert usage.output_tokens == 7

      assert_received {:upstream, body, headers}
      assert headers["authorization"] == "Bearer sk-live"
      assert headers["content-type"] == "application/json"
      refute Map.has_key?(headers, "anthropic-version")
      assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
    end

    test "the resolved model replaces whatever the engine asked for",
         %{bypass: bypass, base_url: base_url} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upstream, Jason.decode!(raw)})
        json(conn, ok_response())
      end)

      assert {:ok, _} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"model" => "engine-asked-for-this", "messages" => []},
                 "resolved-model"
               )

      assert_received {:upstream, %{"model" => "resolved-model"}}
    end

    test "streaming is forced off, including when the engine used atom keys",
         %{bypass: bypass, base_url: base_url} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upstream, Jason.decode!(raw)})
        json(conn, ok_response())
      end)

      # The AI SDK / OpenCode default is `stream: true`. The gateway buffers a
      # single JSON body for metering, so a leaked `stream` surfaces as
      # `upstream_invalid_json`.
      assert {:ok, _} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"messages" => [], :model => "engine-model", :stream => true},
                 "resolved-model"
               )

      assert_received {:upstream, body}
      assert body["stream"] == false
      assert body["model"] == "resolved-model"
      refute Map.has_key?(body, "engine-model")
    end

    test "an anthropic credential carries the API version header",
         %{bypass: bypass, base_url: base_url} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(parent, {:headers, Enum.into(conn.req_headers, %{})})
        json(conn, ok_response())
      end)

      assert {:ok, _} =
               OpenaiCompat.chat_completions(
                 cred(provider: "anthropic", base_url: base_url),
                 %{"messages" => []},
                 "claude-sonnet-4-5"
               )

      assert_received {:headers, %{"anthropic-version" => "2023-06-01"}}
    end

    test "a non-2xx upstream is returned as an error with the status preserved",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 429, ~s({"error":{"message":"rate limited"}}))
      end)

      assert {:error, %{status: 429, error: %{message: message}}} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"messages" => []},
                 "gpt-5-mini"
               )

      assert message =~ "rate limited"
    end

    test "a huge upstream error body is truncated instead of logged whole",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 400, String.duplicate("x", 5_000))
      end)

      assert {:error, %{status: 400, error: %{message: message}}} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"messages" => []},
                 "gpt-5-mini"
               )

      assert String.length(message) == 300
    end

    test "a 2xx body that is not JSON is reported, never treated as an empty turn",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        # This is what an SSE stream looks like to a buffering client.
        Plug.Conn.resp(conn, 200, "data: {\"choices\":[]}\n\ndata: [DONE]\n\n")
      end)

      assert {:error, %{status: 502, error: %{message: "upstream_invalid_json"}}} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"messages" => []},
                 "gpt-5-mini"
               )
    end

    test "an unreachable provider is an error, not a crash", %{bypass: bypass, base_url: base_url} do
      Bypass.down(bypass)

      assert {:error, reason} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"messages" => []},
                 "gpt-5-mini"
               )

      refute match?({:ok, _}, reason)
    end

    test "a provider that accepts but never responds times out instead of hanging forever" do
      silent = start_silent_provider!()

      on_exit(fn -> stop_silent_provider!(silent) end)

      base_url = "http://localhost:#{silent.port}"
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               OpenaiCompat.chat_completions(
                 cred(provider: "openai", base_url: base_url),
                 %{"messages" => []},
                 "gpt-5-mini"
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 5_000
    end
  end

  defp start_silent_provider! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    pid =
      spawn_link(fn ->
        accept_silent(listen, parent)
      end)

    %{port: port, pid: pid, listen: listen}
  end

  defp accept_silent(listen, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        send(parent, {:silent_provider_accept, client})

        spawn(fn ->
          _ = :gen_tcp.recv(client, 0, 60_000)
          receive do
          end
        end)

        accept_silent(listen, parent)

      _ ->
        :ok
    end
  end

  defp stop_silent_provider!(%{listen: listen, pid: pid}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :gen_tcp.close(listen)
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  defp ok_response do
    %{
      "id" => "chatcmpl-test",
      "model" => "gpt-5-mini",
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

  defp cred(attrs) do
    struct!(
      %Credential{
        name: "test-cred",
        provider: "openai",
        model: "gpt-5-mini",
        api_key: "sk-test"
      },
      attrs
    )
  end
end
