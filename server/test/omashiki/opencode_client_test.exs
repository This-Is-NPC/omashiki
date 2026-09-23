defmodule Omashiki.Plugin.HttpTest do
  use ExUnit.Case, async: true

  alias Omashiki.Plugin.Http
  alias Omashiki.Runtime.Capability

  setup do
    bypass = Bypass.open()

    capability = %Capability{
      transport: :http,
      endpoint: %{host: "127.0.0.1", port: bypass.port},
      exec: fn _argv, _timeout -> {:error, :not_used} end
    }

    {:ok, capability: capability, bypass: bypass}
  end

  describe "start_session/2" do
    test "returns session id on 201", %{capability: capability, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/session", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"id":"sess_123"}))
      end)

      assert {:ok, "sess_123"} = Http.start_session(capability, [])
    end

    test "returns http_error on 5xx", %{capability: capability, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/session", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
      end)

      assert {:error, {:http_error, 500, _}} = Http.start_session(capability, [])
    end
  end

  describe "send_turn/3" do
    test "decodes the assistant turn + neutral token counts", %{
      capability: capability,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/session/sess_1/message", fn conn ->
        body = ~s({
          "info": {"modelID": "anthropic/claude-sonnet-4-5", "providerID": "anthropic",
                    "tokens": {"input": 12, "output": 7}},
          "parts": [{"type": "text", "text": "hello"}]
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, response} =
               Http.send_turn(capability, "sess_1", %{
                 parts: [%{type: "text", text: "hi"}]
               })

      assert response.assistant_text == "hello"
      assert response.input_tokens == 12
      assert response.output_tokens == 7
      assert is_nil(response.cached_input_tokens)
      assert is_nil(response.cache_write_tokens)
      assert response.model_resolved == "anthropic/claude-sonnet-4-5"
      assert response.provider == "anthropic"
    end

    test "fails the turn when the session waits for a permission", %{
      capability: capability,
      bypass: bypass
    } do
      # A parked session never answers the turn.
      Bypass.stub(bypass, "POST", "/session/sess_1/message", fn conn ->
        Process.sleep(:infinity)
        conn
      end)

      Bypass.stub(bypass, "GET", "/permission", fn conn ->
        body = ~s([
          {"id": "per_other", "sessionID": "sess_2", "permission": "bash",
           "patterns": ["rm *"], "metadata": {}, "always": []},
          {"id": "per_1", "sessionID": "sess_1", "permission": "external_directory",
           "patterns": ["/etc/*"], "metadata": {}, "always": ["/etc/*"]}
        ])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:error, {:agent_waiting_for_permission, "external_directory", ["/etc/*"]}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)

      # Dropping the turn ends its request handler with :shutdown.
      Bypass.pass(bypass)
    end

    test "keeps waiting while no permission is pending for the session", %{
      capability: capability,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/session/sess_1/message", fn conn ->
        Process.sleep(200)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"info": {}, "parts": [{"type": "text", "text": "done"}]}))
      end)

      Bypass.stub(bypass, "GET", "/permission", fn conn ->
        body = ~s([{"id": "per_other", "sessionID": "sess_2", "permission": "bash",
                    "patterns": ["rm *"], "metadata": {}, "always": []}])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, %{assistant_text: "done"}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)
    end

    test "returns http_error on 422", %{capability: capability, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/session/sess_1/message", fn conn ->
        Plug.Conn.resp(conn, 422, ~s({"error":"bad input"}))
      end)

      assert {:error, {:http_error, 422, _}} =
               Http.send_turn(capability, "sess_1", %{parts: []})
    end
  end

  describe "finish/2" do
    test "treats 204 as :ok", %{capability: capability, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/session/sess_1", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Http.finish(capability, "sess_1")
    end

    test "treats 404 as :ok (idempotent)", %{capability: capability, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/session/sess_1", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert :ok = Http.finish(capability, "sess_1")
    end
  end
end
