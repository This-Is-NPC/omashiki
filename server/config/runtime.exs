import Config

if network = System.get_env("OMASHIKI_AGENT_NETWORK_MODE") do
  config :omashiki, :agent_network_mode, network
end

if url = System.get_env("OMASHIKI_HOUSE_URL") do
  config :omashiki, :house_url, url
end

if network = System.get_env("OMASHIKI_SUPPLY_CHAIN_NETWORK") do
  config :omashiki, :supply_chain_network, network
end

if path = System.get_env("OMASHIKI_SUPPLY_CHAIN_SOCKET_PATH") do
  if Path.type(path) != :absolute,
    do: raise("OMASHIKI_SUPPLY_CHAIN_SOCKET_PATH must be absolute")

  config :omashiki, :supply_chain_socket_path, path
end

case System.get_env("OMASHIKI_ROLE") do
  nil ->
    :ok

  "embedded" ->
    config :omashiki, :boot_role, :embedded

  "manager" ->
    config :omashiki, :boot_role, :manager
    # Manager has no Docker CLI/socket; workers validate images at launch.
    config :omashiki, :plugin_image_provides, :trust

  "worker" ->
    config :omashiki, :boot_role, :worker
    config :omashiki, :worker_executor, Omashiki.Worker.Snapshot
    config :omashiki, OmashikiWeb.Endpoint, server: false

  other ->
    raise "OMASHIKI_ROLE must be embedded, manager, or worker; got #{inspect(other)}"
end

if path = System.get_env("OMASHIKI_DOCKER_SOCKET_PATH") do
  if Path.type(path) != :absolute,
    do: raise("OMASHIKI_DOCKER_SOCKET_PATH must be absolute")

  config :omashiki, :docker_socket_path, path
end

config :omashiki, :worker_token, System.get_env("OMASHIKI_WORKER_TOKEN")
config :omashiki, :manager_url, System.get_env("OMASHIKI_MANAGER_URL")

case System.get_env("OMASHIKI_TRUST_FORWARDED") do
  nil -> :ok
  raw -> config :omashiki, :http_forwarded, raw in ~w(1 true)
end

case System.get_env("OMASHIKI_MANAGERS") do
  nil ->
    :ok

  raw ->
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) ->
        config :omashiki, :worker_managers, list

      {:ok, other} ->
        raise "OMASHIKI_MANAGERS must be a JSON array of objects, got #{inspect(other)}"

      {:error, reason} ->
        raise "OMASHIKI_MANAGERS is not valid JSON: #{inspect(reason)}"
    end
end

config :omashiki,
       :enroll_port,
       String.to_integer(System.get_env("OMASHIKI_ENROLL_PORT") || "4012")

config :omashiki, :enroll_secret, System.get_env("OMASHIKI_ENROLL_SECRET")
config :omashiki, :worker_state_path, System.get_env("OMASHIKI_WORKER_STATE_PATH")

case System.get_env("OMASHIKI_WORKER_CONFIG") do
  nil ->
    :ok

  path ->
    path = Path.expand(path)

    if File.exists?(path) do
      cfg = Toml.decode_file!(path)

      if max = get_in(cfg, ["limits", "max_concurrent_containers"]) do
        config :omashiki, :max_concurrent_containers, max
      end

      if socket = get_in(cfg, ["docker", "socket_path"]) do
        config :omashiki, :docker_socket_path, socket
      end
    end
end

if path = System.get_env("OMASHIKI_LLM_EGRESS_SOCKET_PATH") do
  if Path.type(path) != :absolute,
    do: raise("OMASHIKI_LLM_EGRESS_SOCKET_PATH must be absolute")

  config :omashiki, :llm_egress_socket_path, path
end

if hosts = System.get_env("OMASHIKI_LLM_EGRESS_HOSTS") do
  config :omashiki,
         :llm_egress_hosts,
         String.split(hosts, ",", trim: true) |> Enum.map(&String.trim/1)
end

if size = System.get_env("OMASHIKI_AGENT_TMP_SIZE_MB") do
  case Integer.parse(size) do
    {value, ""} when value > 0 -> config :omashiki, :agent_tmp_size_mb, value
    _ -> raise "OMASHIKI_AGENT_TMP_SIZE_MB must be a positive integer"
  end
end

if containers = System.get_env("OMASHIKI_MAX_CONCURRENT_CONTAINERS") do
  case Integer.parse(containers) do
    {value, ""} when value > 0 -> config :omashiki, :max_concurrent_containers, value
    _ -> raise "OMASHIKI_MAX_CONCURRENT_CONTAINERS must be a positive integer"
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

if config_env() == :prod do
  role = System.get_env("OMASHIKI_ROLE")

  # Every role signs with it: the web roles for cookies, sessions and API
  # tokens, workers for the runtime claims their manager verifies. The cookie
  # store refuses fewer than 64 bytes on every request, so refuse it here.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with `openssl rand -base64 48`; a worker uses the same value as its manager.
      """

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must be at least 64 characters; " <>
            "generate one with `openssl rand -base64 48`"
  end

  if role == "worker" do
    config :omashiki, OmashikiWeb.Endpoint,
      secret_key_base: secret_key_base,
      server: false
  else
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :omashiki, Omashiki.Repo,
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6

    config :omashiki, OmashikiWeb.Endpoint,
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT") || "4000")
      ],
      secret_key_base: secret_key_base,
      server: true
  end
end

# ---------------------------------------------------------------------------
# :install — how this house is installed: :release when a release runs it
# (its start script sets RELEASE_ROOT), :checkout otherwise. The config path
# below and the commands Omashiki.Doctor names follow it.
# ---------------------------------------------------------------------------
install = if System.get_env("RELEASE_ROOT"), do: :release, else: :checkout
config :omashiki, :install, install

# ---------------------------------------------------------------------------
# omashiki.toml — the house configuration file.
#
# One rule names it: OMASHIKI_CONFIG when set, otherwise omashiki.toml at the
# repository root. A release has no repository root, so it reads the file only
# from OMASHIKI_CONFIG. The resolved path becomes :config_path, which
# Omashiki.Config.default_path/0 returns, so the infrastructure read here and
# the registry loaded at boot come from the same file. .scripts/omashiki.py
# config_file() applies the same rule for the dev tasks.
#
# Runs for every environment and comes last in the config chain
# (config.exs -> <env>.exs -> runtime.exs), so it overrides the defaults in
# dev.exs and test.exs rather than competing with them.
#
# A missing file leaves every default untouched. Environment variables still
# win over it so CI can override without editing the file.
# ---------------------------------------------------------------------------
omashiki_toml =
  case System.get_env("OMASHIKI_CONFIG") do
    path when path not in [nil, ""] ->
      Path.expand(path)

    _ ->
      if install == :checkout, do: Path.expand("../../omashiki.toml", __DIR__)
  end

if omashiki_toml, do: config(:omashiki, :config_path, omashiki_toml)

if omashiki_toml && File.exists?(omashiki_toml) do
  cfg =
    case Toml.decode_file(omashiki_toml) do
      {:ok, map} ->
        map

      {:error, reason} ->
        raise "omashiki.toml is present but unreadable: #{inspect(reason)}"
    end

  get = fn section, key -> get_in(cfg, [section, key]) end

  # Env var beats the file; the file beats the code default.
  db_port =
    case System.get_env("OMASHIKI_DB_PORT") do
      nil -> get.("db", "port")
      raw -> String.to_integer(raw)
    end

  # The database port is infrastructure — where Postgres actually listens —
  # so it applies to every environment, `mix test` included. Without it the
  # suite would go looking on 5432 while the container is on 5442.
  if db_port, do: config(:omashiki, Omashiki.Repo, port: db_port)
end

# Everything below is operator preference rather than infrastructure, and the
# test suite has to stay hermetic: a developer running with `auth.enabled =
# false` must not watch the auth-gate tests fail because of their own local
# config. Ports and flags for the running app only.
if omashiki_toml && File.exists?(omashiki_toml) && config_env() != :test do
  cfg = Toml.decode_file!(omashiki_toml)
  get = fn section, key -> get_in(cfg, [section, key]) end

  http_port =
    case System.get_env("PORT") do
      nil -> get.("app", "port")
      raw -> String.to_integer(raw)
    end

  http_ip =
    case get.("app", "host") do
      nil ->
        nil

      host ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, ip} -> ip
          {:error, _} -> raise "omashiki.toml: app.host is not an IP address: #{inspect(host)}"
        end
    end

  http_opts =
    []
    |> then(&if(http_port, do: [{:port, http_port} | &1], else: &1))
    |> then(&if(http_ip, do: [{:ip, http_ip} | &1], else: &1))

  if http_opts != [] do
    config(:omashiki, OmashikiWeb.Endpoint, http: http_opts)
  end

  # `auth.enabled` maps onto the `:auth_mode` that already exists rather than
  # introducing a second switch for the same thing. See OmashikiWeb.AuthMode.
  case get.("auth", "enabled") do
    false -> config(:omashiki, :auth_mode, :none)
    true -> config(:omashiki, :auth_mode, :bearer)
    nil -> :ok
    other -> raise "omashiki.toml: auth.enabled must be true or false, got #{inspect(other)}"
  end

  case get.("auth", "token_max_ttl_days") do
    nil ->
      :ok

    days when is_integer(days) and days >= 1 and days <= 365 ->
      config(:omashiki, :token_max_ttl_days, days)

    other ->
      raise "omashiki.toml: auth.token_max_ttl_days must be an integer 1..365, got #{inspect(other)}"
  end

  case get.("auth", "token_audit_retention_days") do
    nil ->
      :ok

    days when is_integer(days) and days >= 1 ->
      config(:omashiki, :token_audit_retention_days, days)

    other ->
      raise "omashiki.toml: auth.token_audit_retention_days must be a positive integer, got #{inspect(other)}"
  end
end

# Mix config files cannot read Application.get_env/2 reliably. Merge only
# thousand_island_options so a later get_env rewrite cannot replace app.host
# and app.port from omashiki.toml.
idle_ms = Application.get_env(:omashiki, :http_idle_timeout_ms)

if is_integer(idle_ms) do
  config :omashiki, OmashikiWeb.Endpoint, http: [thousand_island_options: [read_timeout: idle_ms]]
end
