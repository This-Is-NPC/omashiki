defmodule OmashikiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :omashiki

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_omashiki_web_key",
    signing_salt: "OiEgE6kx",
    same_site: "Lax"
  ]

  # assets/js/app.js has always connected here. Without this declaration there
  # was nothing on the other end, so every LiveView rendered once and stayed
  # dead: `connected?/1` was permanently false, which quietly disabled the
  # periodic refresh in OverviewLive and every PubSub subscription behind it.
  #
  # `:peer_data` is requested because OmashikiWeb.AuthHooks needs the peer
  # address to keep /dashboard off the LAN when login is disabled — over the
  # websocket that is only readable if the socket asks for it at connect time.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options]],
    longpoll: [connect_info: [:peer_data, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :omashiki,
    gzip: false,
    only: OmashikiWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :omashiki
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug OmashikiWeb.Router
end
