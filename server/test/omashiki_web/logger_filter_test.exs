defmodule OmashikiWeb.LoggerFilterTest do
  use ExUnit.Case, async: false

  require Logger

  alias OmashikiWeb.LoggerFilter

  test "scrubs Authorization header values" do
    event = %{
      meta: %{
        conn: %Plug.Conn{
          req_headers: [{"authorization", "Bearer secret-1234"}, {"x-other", "ok"}],
          query_string: ""
        }
      }
    }

    %{meta: %{conn: conn}} = LoggerFilter.filter(event, [])
    assert {"authorization", "[REDACTED]"} in conn.req_headers
    assert {"x-other", "ok"} in conn.req_headers
  end

  test "scrubs ?token= from a query string" do
    qs = "token=plaintext-1&foo=bar"
    event = %{meta: %{query_string: "?" <> qs}}
    %{meta: %{query_string: qs2}} = LoggerFilter.filter(event, [])
    refute qs2 =~ "plaintext-1"
    assert qs2 =~ "[REDACTED]"
  end

  test "scrubs supply-chain tokens from request paths" do
    token = "signed-secret-token"
    path = "/api/v1/supply-chain/packages/npm/#{token}/left-pad"
    event = %{meta: %{request_path: path, conn: %Plug.Conn{request_path: path}}}

    %{meta: %{request_path: filtered, conn: conn}} = LoggerFilter.filter(event, [])

    refute filtered =~ token
    refute conn.request_path =~ token
    assert filtered =~ "[REDACTED]"
  end

  test "leaves unrelated metadata alone" do
    event = %{meta: %{request_id: "abc", level: :info}}
    assert ^event = LoggerFilter.filter(event, [])
  end

  describe "primary :logger filter installed by Application.start/2" do
    @secret_token "do-not-leak-this-token-1234567890"

    setup do
      # Capture every log line for the duration of the test.
      Logger.configure(level: :info)
      previous_meta = Logger.metadata()
      on_exit(fn -> Logger.metadata(previous_meta) end)
      :ok
    end

    test "the installed filter scrubs an Authorization header from a real conn-tagged log" do
      conn = %Plug.Conn{
        method: "GET",
        request_path: "/api/v1/jobs",
        query_string: "token=" <> @secret_token,
        req_headers: [{"authorization", "Bearer " <> @secret_token}]
      }

      output =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          Logger.info("hit",
            conn: conn,
            request_path: "/api/v1/jobs",
            query_string: "token=" <> @secret_token
          )
        end)

      refute output =~ @secret_token,
             "logger leaked the bearer token plaintext into the captured output: #{output}"
    end

    test "ordinary log lines that mention the word 'token' survive" do
      output =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          Logger.info("user discussed how to rotate their token")
        end)

      assert output =~ "rotate their token"
    end
  end
end
