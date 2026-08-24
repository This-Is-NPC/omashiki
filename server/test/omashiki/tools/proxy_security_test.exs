defmodule Omashiki.Tools.ProxySecurityTest do
  use ExUnit.Case, async: true

  alias Omashiki.Tools.Proxy

  test "rejects MCP upstream SSRF targets and credential-bearing URLs" do
    assert {:error, :restricted_destination} = Proxy.authorize_upstream("http://127.0.0.1/mcp")
    assert {:error, :restricted_destination} = Proxy.authorize_upstream("http://[::1]/mcp")

    assert {:error, :upstream_userinfo_not_allowed} =
             Proxy.authorize_upstream("https://user:secret@example.test/mcp")

    assert :ok = Proxy.authorize_upstream("https://93.184.216.34/mcp")
  end
end
