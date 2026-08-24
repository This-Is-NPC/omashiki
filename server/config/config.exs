# This file is responsible for configuring the application and its
# dependencies with the help of the Config module.
import Config

# Configure Mix tasks and generators
config :omashiki,
  ecto_repos: [Omashiki.Repo],
  generators: [context_app: :omashiki]

# API auth. `:bearer` (default) always requires a token/session.
# `:none` skips credentials only for loopback peers AND only when the
# Endpoint binds to loopback — refused at boot otherwise (LAN = Bearer).
config :omashiki, :auth_mode, :bearer

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".

# Configures the endpoint
config :omashiki, OmashikiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OmashikiWeb.ErrorHTML, json: OmashikiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Omashiki.PubSub,
  live_view: [signing_salt: "t5EQju1M"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  omashiki: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  omashiki: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Register text/event-stream MIME type for job event streaming
config :mime, :types, %{
  "text/event-stream" => ["event-stream"]
}

# Job events remain streamable for this durable observation horizon.
config :omashiki, :job_event_retention_days, 30

# Oban retains durable queue rows for the same 30-day horizon as job data.
config :omashiki, Oban,
  repo: Omashiki.Repo,
  queues: [scheduler: 10, webhooks: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
