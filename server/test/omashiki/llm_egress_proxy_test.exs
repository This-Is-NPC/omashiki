defmodule Omashiki.LlmEgress.ProxyTest do
  use ExUnit.Case, async: true

  alias Omashiki.LlmEgress.Proxy

  test "allows an exact hostname with a public resolved address" do
    resolver = fn "api.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, [{93, 184, 216, 34}]} =
             Proxy.authorize_destination("api.example.test",
               hosts: ["api.example.test"],
               resolver: resolver
             )
  end

  test "rejects a host outside the exact allowlist without resolving it" do
    resolver = fn _host -> flunk("the non-allowlisted host must not be resolved") end

    assert {:error, :not_allowlisted} =
             Proxy.authorize_destination("other.example.test",
               hosts: ["api.example.test"],
               resolver: resolver
             )
  end

  test "rejects methods other than CONNECT and ports other than 443" do
    assert {:error, {405, "Method Not Allowed"}} =
             Proxy.parse_connect_request("GET api.example.test:443 HTTP/1.1\r\n\r\n")

    assert {:error, {400, "Bad Request"}} =
             Proxy.parse_connect_request("CONNECT api.example.test:8443 HTTP/1.1\r\n\r\n")
  end

  test "rejects private addresses returned by the resolver" do
    resolver = fn "api.example.test" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 7}]} end

    assert {:error, :restricted_destination} =
             Proxy.authorize_destination("api.example.test",
               hosts: ["api.example.test"],
               resolver: resolver
             )
  end

  test "rejects IP literals even when the literal is in the allowlist" do
    assert {:error, {403, "Forbidden"}} =
             Proxy.parse_connect_request("CONNECT 93.184.216.34:443 HTTP/1.1\r\n\r\n")
  end
end
