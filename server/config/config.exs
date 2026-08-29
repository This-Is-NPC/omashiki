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
  # Generator value, shared by every environment and safe to track: it salts
  # LiveView session signing, which is already bound to secret_key_base — and
  # that comes from SECRET_KEY_BASE in production. See config/dev.exs.
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

# Outbound provider HTTP must not block a DispatchWorker forever. The receive
# loop enforces this as a total request deadline (connect timeout is separate).
config :omashiki, :gateway_provider_request_timeout_ms, 120_000

# Dispatch waits for the attempt coordinator at most job `timeout_ms` plus this
# slack. Without a bound, a hung runner keeps heartbeating and Oban stays in
# `executing` until Lifeline fires.
config :omashiki, :dispatch_await_slack_ms, 60_000

# Oban retains durable queue rows for the same 30-day horizon as job data.
# The `scheduler` limit is a second, independent concurrency ceiling: it caps how
# many DispatchWorkers run at once, so it bounds live attempts regardless of
# `[limits] max_concurrent_containers` in omashiki.toml. The smaller of the two
# wins — leave them consistent or the TOML advertises a capacity the queue will
# never grant. Set it to 0 to keep HTTP admission enabled without starting a
# scheduler consumer in this process.
oban_scheduler_limit =
  case System.get_env("OBAN_SCHEDULER_LIMIT") do
    nil ->
      10

    raw ->
      case Integer.parse(raw) do
        {limit, ""} when limit >= 0 -> limit
        _ -> raise "OBAN_SCHEDULER_LIMIT must be a non-negative integer"
      end
  end

oban_queues =
  if oban_scheduler_limit == 0 do
    [webhooks: 5]
  else
    [scheduler: oban_scheduler_limit, webhooks: 5]
  end

config :omashiki, Oban,
  repo: Omashiki.Repo,
  queues: oban_queues,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
    # A node that dies mid-`perform` leaves its dispatch parked in `executing`.
    # Nothing else reclaims it: `executing` is one of Oban's *incomplete* states,
    # so `DispatchWorker`'s uniqueness still counts it as live and
    # `Jobs.recover_orphaned_dispatches/1` deliberately skips it. Lifeline is the
    # only thing that returns those rows to `available`, which is why the
    # multi-node orphan case is handled here rather than in the sweep.
    #
    # `rescue_after` must stay above the longest legitimate run, or Lifeline
    # rescues jobs that are still executing on a live node — it ages rows by
    # `attempted_at` and does not check node liveness. The harness ceiling is
    # `timeout_ms = 1_800_000` (30 min) plus pre-steps, so the 60 minute default
    # is the floor, not a number to trim. A premature rescue is not a double
    # container run in any case: the re-dispatch finds the job past `queued` and
    # `Jobs.claim/3` refuses it, so the retry is a no-op.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
