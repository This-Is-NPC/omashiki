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
      park_turn(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_other", "sessionID": "sess_2", "permission": "bash",
         "patterns": ["rm *"], "metadata": {}, "always": []},
        {"id": "per_1", "sessionID": "sess_1", "permission": "external_directory",
         "patterns": ["/etc/*"], "metadata": {}, "always": ["/etc/*"]}
      ]))

      stub_json(bypass, "/session/sess_2", ~s({"id": "sess_2"}))

      assert {:error, {:agent_waiting_for_permission, "external_directory", ["/etc/*"], false}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)

      # Dropping the turn ends its request handler with :shutdown.
      Bypass.pass(bypass)
    end

    test "fails the turn when a subagent waits for a permission", %{
      capability: capability,
      bypass: bypass
    } do
      park_turn(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_1", "sessionID": "sess_child", "permission": "read",
         "patterns": [".env"], "metadata": {}, "always": [".env"]}
      ]))

      stub_json(bypass, "/session/sess_child", ~s({"id": "sess_child", "parentID": "sess_1"}))

      assert {:error, {:agent_waiting_for_permission, "read", [".env"], true}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)

      Bypass.pass(bypass)
    end

    test "fails the turn when a nested subagent waits for a permission", %{
      capability: capability,
      bypass: bypass
    } do
      park_turn(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_1", "sessionID": "sess_grandchild", "permission": "read",
         "patterns": [".env"], "metadata": {}, "always": [".env"]}
      ]))

      stub_json(
        bypass,
        "/session/sess_grandchild",
        ~s({"id": "sess_grandchild", "parentID": "sess_child"})
      )

      stub_json(bypass, "/session/sess_child", ~s({"id": "sess_child", "parentID": "sess_1"}))

      assert {:error, {:agent_waiting_for_permission, "read", [".env"], true}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)

      Bypass.pass(bypass)
    end

    test "keeps waiting while no permission is pending for the session", %{
      capability: capability,
      bypass: bypass
    } do
      answer_turn_late(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_other", "sessionID": "sess_3", "permission": "bash",
         "patterns": ["rm *"], "metadata": {}, "always": []}
      ]))

      # sess_3 is a subagent of another root session.
      stub_json(bypass, "/session/sess_3", ~s({"id": "sess_3", "parentID": "sess_2"}))
      stub_json(bypass, "/session/sess_2", ~s({"id": "sess_2"}))

      assert {:ok, %{assistant_text: "done"}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)
    end

    test "keeps waiting when the asking session cannot be read", %{
      capability: capability,
      bypass: bypass
    } do
      answer_turn_late(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_1", "sessionID": "sess_child", "permission": "read",
         "patterns": [".env"], "metadata": {}, "always": [".env"]}
      ]))

      Bypass.stub(bypass, "GET", "/session/sess_child", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
      end)

      assert {:ok, %{assistant_text: "done"}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)
    end

    test "keeps waiting when the parent chain loops", %{
      capability: capability,
      bypass: bypass
    } do
      answer_turn_late(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_1", "sessionID": "sess_a", "permission": "read",
         "patterns": [".env"], "metadata": {}, "always": [".env"]}
      ]))

      stub_json(bypass, "/session/sess_a", ~s({"id": "sess_a", "parentID": "sess_b"}))
      stub_json(bypass, "/session/sess_b", ~s({"id": "sess_b", "parentID": "sess_a"}))

      assert {:ok, %{assistant_text: "done"}} =
               Http.send_turn(capability, "sess_1", %{parts: []}, permission_poll_ms: 20)
    end

    test "keeps waiting when the parent chain is deeper than any subagent nesting", %{
      capability: capability,
      bypass: bypass
    } do
      answer_turn_late(bypass)

      stub_json(bypass, "/permission", ~s([
        {"id": "per_1", "sessionID": "sess_d0", "permission": "read",
         "patterns": [".env"], "metadata": {}, "always": [".env"]}
      ]))

      # sess_d0 -> sess_d1 -> ... -> sess_d19 -> sess_1
      for depth <- 0..19 do
        parent = if depth == 19, do: "sess_1", else: "sess_d#{depth + 1}"
        stub_json(bypass, "/session/sess_d#{depth}", ~s({"parentID": "#{parent}"}))
      end

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

  # A parked session never answers the turn.
  defp park_turn(bypass) do
    Bypass.stub(bypass, "POST", "/session/sess_1/message", fn conn ->
      Process.sleep(:infinity)
      conn
    end)
  end

  defp answer_turn_late(bypass) do
    Bypass.expect_once(bypass, "POST", "/session/sess_1/message", fn conn ->
      Process.sleep(200)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"info": {}, "parts": [{"type": "text", "text": "done"}]}))
    end)
  end

  defp stub_json(bypass, path, body) do
    Bypass.stub(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)
  end
end
