import Config

# Argon2 — drop cost knobs to the lowest valid values for tests so that
# `setup_user/1` and password-roundtrip tests don't dominate runtime.
config :argon2_elixir, t_cost: 1, m_cost: 8

# Keep tests independent of the developer's omashiki.toml.
config :omashiki, :skip_toml_config, true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :omashiki, Omashiki.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("OMASHIKI_DB_PORT") || "5432"),
  database: "omashiki_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The real-provider E2E needs a host listener so its Docker container can
# reach the LLM gateway. All other tests keep the endpoint in-process only.
real_provider_e2e? = System.get_env("OMASHIKI_REAL_PROVIDER_E2E") in ["1", "true"]

config :omashiki, OmashikiWeb.Endpoint,
  http: [ip: if(real_provider_e2e?, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}), port: 4002],
  secret_key_base: "jSFNlVDVIxgZfZLWyf5VWNo2dpYxAVeg2GVvf0ljqPdJyeR03ShT9UtkaZXJ/mfx",
  server: real_provider_e2e?

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# `ApiTokens.record_use/1` hands its `last_used_at` write to a supervised task
# in every environment that serves requests. Under `Ecto.Adapters.SQL.Sandbox`
# that task is not the process that owns the connection, so its checkout fails
# with "owner exited" once the test ends. Run it inline here: same statement,
# same guard, but on the owner process.
config :omashiki, :api_token_use_write, :inline

# Skip on-boot orphan cleanup (no Docker socket / repo dirs in unit tests).
config :omashiki, :run_orphan_cleanup_on_boot, false

# The runtime graph joins a container census onto processes and attempt rows.
# Tests drive the container half explicitly; without this the shared inspector
# would reach for whatever Docker daemon the developer happens to be running and
# fold their real containers into the assertions.
config :omashiki, :runtime_census, {Omashiki.Runtime.Inspector, :empty_census, []}

# …and the shared inspector never polls on its own here. `async: false` tests
# share one sandbox connection with every other process, so a background poll
# would queue behind — and ahead of — the queries a timing-sensitive test is
# making. Tests call `Inspector.refresh/0` when they want a census.
config :omashiki, :runtime_inspector_interval_ms, :timer.hours(1)
config :omashiki, :enable_job_recovery, false

# The capacity row is owned by the sandbox; tests call `Jobs.sync_capacity/0`.
config :omashiki, :sync_execution_capacity_on_boot, false

# Oban — manual testing mode: jobs are not auto-executed; tests call
# `Oban.drain_queue/1` or `perform_job/2` explicitly.
config :omashiki, Oban, testing: :manual

# Host credential copies stay inside the test sandbox, never /dev/shm.
config :omashiki,
       :host_credential_root,
       Path.join(
         System.tmp_dir!(),
         "omashiki-credentials-test#{System.get_env("MIX_TEST_PARTITION")}"
       )
