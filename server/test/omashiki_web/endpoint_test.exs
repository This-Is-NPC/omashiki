defmodule OmashikiWeb.EndpointTest do
  use ExUnit.Case, async: true

  # assets/js/app.js has always done `new LiveSocket("/live", Socket, ...)`.
  # If the endpoint does not answer there, every LiveView in the console renders
  # exactly once and never connects: `connected?/1` stays false forever, so the
  # periodic refresh in OverviewLive never schedules and no PubSub subscription
  # is ever taken out. Nothing fails loudly — the screens simply stop being live.
  test "the endpoint serves the live socket the browser connects to" do
    paths = Enum.map(OmashikiWeb.Endpoint.__sockets__(), fn {path, _handler, _opts} -> path end)

    assert "/live" in paths,
           "assets/js/app.js connects to \"/live\"; the endpoint declares #{inspect(paths)}"
  end

  # The gate on /dashboard reads the peer address to keep BEAM internals off the
  # LAN when login is disabled. Over the websocket that address is only readable
  # when the socket asks for it at connect time.
  test "the live socket captures peer data for the console gate" do
    {_path, _handler, opts} =
      Enum.find(OmashikiWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

    for transport <- [:websocket, :longpoll] do
      connect_info = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:connect_info)

      assert :peer_data in connect_info,
             "#{transport} must request :peer_data, got #{inspect(connect_info)}"

      assert Keyword.has_key?(connect_info, :session),
             "#{transport} must forward the session, got #{inspect(connect_info)}"
    end
  end
end
