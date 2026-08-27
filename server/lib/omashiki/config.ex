defmodule Omashiki.Config do
  @moduledoc """
  Declared host configuration from `omashiki.toml`.

  Production configuration declares repositories, governed environments,
  credentials, host credentials, caches, execution nodes, and host limits. Jobs
  capture repository/environment values and their digest at admission so later
  reloads cannot alter them.

  `[nodes]` is optional. Without it there is exactly one implicit node — this
  machine — and every path behaves as it did before nodes existed.

  ## Generations

  `reload/1` re-reads the file into `:persistent_term` without a restart, and
  every successful write bumps `generation/0`. Exactly **one** generation lives
  in `:persistent_term` at a time — the live one, which admission resolves
  against. The generations still owed to running work are not held in memory at
  all: each job captured its own `admitted_repository`, `admitted_environment`
  and `registry_digest` at admission, so the prior generation lives durably in
  the `jobs` row that needs it. That is what bounds the writes. `:persistent_term.put/2`
  scans every process holding a reference to the old term, so it is paid once
  per successful reload and never per job, per attempt or on a timer.

  A failed reload writes nothing. `load!/1` builds the whole snapshot — parsing,
  validating and resolving every `${env:VAR}` — *before* it reaches
  `put_snapshot!/1`, so an unset variable raises with the previous generation
  still in `:persistent_term` and still serving. A stale config is recoverable;
  a half-applied one is not.

  ## Failures

  `load!/1` raises `Omashiki.Config.Error` (never a raw `KeyError`) when:

    * the file is missing
    * a required top-level section is missing (`repositories`, `environments`, `presets`,
      or `limits`; `credentials`, `host_credentials`, and `caches` are optional)
    * a required field on an entry is missing
  """

  alias Omashiki.Credentials.Credential
  alias Omashiki.Config.{HostCredential, Machine, Registry, ResolvedJob}
  alias Omashiki.Runtimes.CacheGroup
  alias Omashiki.SupplyChain.Policy

  defmodule Error do
    @moduledoc "Readable failure loading `omashiki.toml`."
    defexception [:message]

    @impl true
    def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
  end

  @persistent_key {__MODULE__, :snapshot}
  @cache_name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @cache_env_allowlist ~w(
    MISE_DATA_DIR MISE_CACHE_DIR XDG_CACHE_HOME
    npm_config_cache PNPM_HOME CARGO_HOME GOPATH GOMODCACHE
    UV_CACHE_DIR PIP_CACHE_DIR MIX_HOME HEX_HOME
  )
  # Domain sections that must appear in a real TOML file. `credentials` is
  # optional when jobs use host-authenticated providers.
  @required_sections ~w(repositories environments presets limits)

  # How a hot reload lands. `[limits]` is per-container resource budget and
  # `HostSettings` takes exactly four keys out of it; a rollout strategy is not
  # one of those, so it gets its own optional section rather than riding along.
  @default_reload_policy %{mode: :gradual, drain_timeout_ms: 300_000}
  @reload_modes %{"gradual" => :gradual, "drain_all" => :drain_all}

  @empty %{
    credentials: [],
    host_credentials: [],
    caches: [],
    presets: [],
    repositories: [],
    environments: [],
    nodes: [],
    current_machine: nil,
    registry_digest: nil,
    limits: %{},
    reload_policy: @default_reload_policy,
    generation: 0,
    loaded_at: nil,
    path: nil,
    source: :empty
  }

  @doc "Default path: repo-root `omashiki.toml` (two levels above `server/`)."
  def default_path do
    Path.expand("../../../omashiki.toml", __DIR__)
  end

  @doc """
  Load `omashiki.toml` into persistent_term.

  Raises `Omashiki.Config.Error` when the file is missing, a required
  section is absent, a required field is missing, or the TOML is unreadable.
  """
  def load!(path \\ default_path()) when is_binary(path) do
    unless File.exists?(path) do
      raise Error, "omashiki.toml not found at #{path}"
    end

    case Toml.decode_file(path) do
      {:ok, map} ->
        put_snapshot!(build_snapshot!(map, path, :toml, require_sections?: true))

      {:error, reason} ->
        raise Error, "omashiki.toml at #{path} is unreadable: #{format_reason(reason)}"
    end
  end

  @doc """
  Build a snapshot from an already-decoded map (tests / injectors).

  Validates required fields on entries that are present. Does **not** require
  every top-level section (fixtures may inject a subset). Pass
  `require_sections?: true` to mirror `load!/1`.
  """
  def load_map!(map, opts \\ []) when is_map(map) do
    path = Keyword.get(opts, :path)
    require_sections? = Keyword.get(opts, :require_sections?, false)
    put_snapshot!(build_snapshot!(map, path, :map, require_sections?: require_sections?))
  end

  @doc """
  Re-read `path` into the live generation. Never raises.

  Returns `{:ok, info}` with the new `:generation`, `:digest` and whether the
  registry digest actually moved, or `{:error, message}` with the previous
  generation untouched and still serving.
  """
  def reload(path \\ default_path()) when is_binary(path) do
    previous = snapshot()

    try do
      load!(path)
    rescue
      error -> {:error, Exception.message(error)}
    else
      :ok ->
        current = snapshot()

        {:ok,
         %{
           generation: current.generation,
           digest: current.registry_digest,
           previous_digest: previous.registry_digest,
           changed?: current.registry_digest != previous.registry_digest
         }}
    end
  end

  @doc "Monotonic counter of successful snapshot writes."
  def generation, do: snapshot().generation

  @doc "When the live generation was written, or nil before the first load."
  def loaded_at, do: snapshot().loaded_at

  @doc """
  Declared `[reload]` policy: `%{mode: :gradual | :drain_all, drain_timeout_ms: pos_integer}`.
  """
  def reload_policy, do: snapshot().reload_policy

  # The single `:persistent_term` write. Everything above it can raise; nothing
  # below it can, so the term is either the whole previous generation or the
  # whole new one.
  defp put_snapshot!(%{} = built) do
    generation = snapshot().generation + 1

    next =
      built
      |> normalize_snapshot()
      |> Map.put(:generation, generation)
      |> Map.put(:loaded_at, DateTime.utc_now())

    :persistent_term.put(@persistent_key, next)
    :ok
  end

  @doc "Clear to an empty snapshot (test hermeticity)."
  def reset! do
    put_snapshot!(@empty)
  end

  @doc "True when a non-empty declarative section was loaded from TOML/map."
  def loaded? do
    snap = snapshot()
    snap.source in [:toml, :map] and declarative?(snap)
  end

  def credentials, do: snapshot().credentials
  def host_credentials, do: snapshot().host_credentials
  def caches, do: snapshot().caches
  def presets, do: snapshot().presets
  def repositories, do: snapshot().repositories
  def environments, do: snapshot().environments
  def current_digest, do: snapshot().registry_digest

  @doc """
  Declared execution nodes, or the single implicit local node.

  An `omashiki.toml` with no `[nodes]` section yields exactly one node — this
  machine — so every caller sees the same shape whether or not the operator has
  declared a cluster.
  """
  def nodes do
    case snapshot().nodes do
      [] -> [current_machine()]
      nodes -> nodes
    end
  end

  @doc """
  The node this process runs on.

  Resolved once at load. Falls back to the implicit local node when no
  configuration has been loaded at all, so it never returns nil and never
  raises on the claim path.
  """
  def current_machine, do: snapshot().current_machine || local_machine()

  @doc "Current immutable repository/environment registry snapshot."
  def current_snapshot do
    Map.take(snapshot(), [:repositories, :presets, :environments, :registry_digest])
  end

  @doc "Resolve names to values captured for one admitted job."
  def resolve_job(repository_name, environment_name) when is_binary(environment_name) do
    snapshot = snapshot()

    case Enum.find(snapshot.environments, &(&1.name == environment_name)) do
      nil ->
        {:error, :unknown_environment}

      %{sink: sink} = environment ->
        resolve_for_sink(snapshot, repository_name, environment, sink)
    end
  end

  def resolve_job(_, _), do: {:error, :invalid_reference}

  defp resolve_for_sink(snapshot, repository_name, environment, sink) do
    with :ok <- validate_repo_for_sink(repository_name, sink) do
      case sink do
        "git" ->
          case Enum.find(snapshot.repositories, &(&1.name == repository_name)) do
            nil ->
              {:error, :unknown_repository}

            repository ->
              {:ok,
               %ResolvedJob{
                 repository: repository,
                 environment: environment,
                 digest: snapshot.registry_digest
               }}
          end

        sink when sink in ["files", "none"] ->
          {:ok,
           %ResolvedJob{
             repository: nil,
             environment: environment,
             digest: snapshot.registry_digest
           }}
      end
    end
  end

  defp validate_repo_for_sink(repository_name, "git") when is_binary(repository_name), do: :ok
  defp validate_repo_for_sink(nil, "git"), do: {:error, :repository_required}
  defp validate_repo_for_sink(nil, sink) when sink in ["files", "none"], do: :ok

  defp validate_repo_for_sink(_repository_name, sink) when sink in ["files", "none"],
    do: {:error, :repository_not_allowed}

  defp validate_repo_for_sink(_, _), do: {:error, :invalid_reference}

  def get_repository(name) when is_binary(name),
    do: Enum.find(repositories(), &(&1.name == name))

  def get_repository(_), do: nil

  def get_environment(name) when is_binary(name),
    do: Enum.find(environments(), &(&1.name == name))

  def get_environment(_), do: nil

  @doc """
  Effective resource limits map.

  Keys match `HostSettings` (`nano_cpus`, `memory_bytes`, …) plus
  `max_concurrent_containers` when declared. Empty map when `[limits]` absent
  or empty.
  """
  def limits, do: snapshot().limits

  def limits_declared?, do: map_size(limits()) > 0

  @doc "Credential by name, or nil."
  def get_credential(name) when is_binary(name) do
    Enum.find(credentials(), &(&1.name == name))
  end

  def get_credential(_), do: nil

  @doc "Host credential by name, or nil."
  def get_host_credential(name) when is_binary(name) do
    Enum.find(host_credentials(), &(&1.name == name))
  end

  def get_host_credential(_), do: nil

  @doc "Cache group by TOML name, or nil."
  def get_cache(name) when is_binary(name) do
    Enum.find(caches(), &(&1.name == name))
  end

  def get_cache(_), do: nil

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp snapshot do
    case :persistent_term.get(@persistent_key, :missing) do
      :missing -> @empty
      %{} = snap -> snap
    end
  end

  defp normalize_snapshot(snap) do
    Map.merge(@empty, Map.take(snap, Map.keys(@empty)))
  end

  defp declarative?(%{
         credentials: c,
         host_credentials: hc,
         caches: ca,
         repositories: repositories,
         environments: environments,
         limits: l
       }) do
    c != [] or hc != [] or ca != [] or repositories != [] or environments != [] or map_size(l) > 0
  end

  # Which of the declared nodes is this machine?
  #
  # `OMASHIKI_NODE` names it explicitly; the hostname is the fallback, so a
  # machine whose host name matches its declaration needs no environment at all.
  #
  # No `[nodes]` section means the distributed path is not in use: one implicit
  # local node, and nothing to disagree with. A single declared node is that
  # node by construction — declaring it is how an operator names the machine.
  #
  # Beyond that the mismatch is loud. A machine that is not in the list would
  # otherwise claim work and stamp attempts with a node id no other machine, and
  # no per-node capacity row, has ever heard of. Failing config load is the only
  # place that is still cheap to notice.
  defp resolve_current_machine!([]), do: local_machine()
  defp resolve_current_machine!([%Machine{} = only]), do: only

  defp resolve_current_machine!(nodes) do
    name = local_machine_name()

    Enum.find(nodes, &(&1.name == name)) ||
      raise Error,
            "this machine is #{inspect(name)}, which is not declared in [nodes]; " <>
              "set OMASHIKI_NODE to one of #{inspect(Enum.map(nodes, & &1.name))}"
  end

  defp local_machine, do: %Machine{name: local_machine_name()}

  defp local_machine_name do
    case System.get_env("OMASHIKI_NODE") do
      name when is_binary(name) and name != "" -> name
      _ -> hostname()
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, host} -> List.to_string(host)
      _ -> "local"
    end
  end

  defp build_snapshot!(map, path, source, opts) when is_map(map) do
    map = stringify_keys(map)
    reject_legacy_sections!(map)

    if Keyword.get(opts, :require_sections?, false) do
      Enum.each(@required_sections, fn section ->
        unless Map.has_key?(map, section) do
          raise Error, "omashiki.toml missing required section [#{section}]"
        end
      end)
    end

    caches = build_caches!(section(map, "caches"))
    credentials = build_credentials!(section(map, "credentials"))
    host_credentials = HostCredential.build!(section(map, "host_credentials"))

    base_dir = if is_binary(path), do: Path.dirname(Path.expand(path)), else: File.cwd!()
    plugins_dir = plugins_dir_for(base_dir)
    plugins = Omashiki.Plugin.Loader.load!(plugins_dir)

    registry =
      Registry.build!(
        section(map, "repositories"),
        section(map, "environments"),
        section(map, "presets"),
        section(map, "nodes"),
        caches,
        credentials,
        host_credentials,
        base_dir,
        plugins
      )

    limits = build_limits(section_map(map, "limits"))
    reload_policy = build_reload_policy!(section_map(map, "reload"))

    %{
      credentials: credentials,
      host_credentials: host_credentials,
      caches: caches,
      presets: registry.presets,
      repositories: registry.repositories,
      environments: registry.environments,
      nodes: registry.nodes,
      current_machine: resolve_current_machine!(registry.nodes),
      registry_digest: registry.registry_digest,
      limits: limits,
      reload_policy: reload_policy,
      path: path,
      source: source
    }
  end

  defp build_reload_policy!(section) when map_size(section) == 0, do: @default_reload_policy

  defp build_reload_policy!(section) do
    section = stringify_keys(section)
    reject_unknown_fields!(section, ~w(mode drain_timeout_ms), "reload")

    mode =
      case Map.get(section, "mode", "gradual") do
        value when is_binary(value) ->
          Map.get(@reload_modes, value) ||
            raise Error,
                  "reload.mode must be one of #{inspect(Map.keys(@reload_modes))}, got #{inspect(value)}"

        other ->
          raise Error, "reload.mode must be a string, got #{type_name(other)}"
      end

    drain_timeout_ms =
      case Map.get(section, "drain_timeout_ms", @default_reload_policy.drain_timeout_ms) do
        n when is_integer(n) and n > 0 ->
          n

        other ->
          raise Error, "reload.drain_timeout_ms must be a positive integer, got #{inspect(other)}"
      end

    %{mode: mode, drain_timeout_ms: drain_timeout_ms}
  end

  defp section(map, key) do
    case Map.get(map, key) do
      %{} = nested ->
        nested

      nil ->
        %{}

      other ->
        raise Error, "omashiki.toml [#{key}] must be a table, got #{type_name(other)}"
    end
  end

  defp section_map(map, key) do
    case Map.get(map, key) do
      %{} = nested ->
        nested

      nil ->
        %{}

      other ->
        raise Error, "omashiki.toml [#{key}] must be a table, got #{type_name(other)}"
    end
  end

  defp build_caches!(section) do
    section
    |> Enum.map(fn {name, attrs} ->
      where = "caches.#{name}"
      attrs = require_table!(attrs, where)

      unless Regex.match?(@cache_name, name) do
        raise Error, "#{where}: cache name must be kebab-case"
      end

      host = require_field!(attrs, "host", where)

      unless is_binary(host) do
        raise Error, "#{where}: host must be a string path"
      end

      expanded_host = expand_path(host)

      unless Path.type(expanded_host) == :absolute do
        raise Error, "#{where}: host must expand to an absolute path"
      end

      unless cache_path?(expanded_host) do
        raise Error, "#{where}: host must be inside #{cache_root()}"
      end

      if symlink_in_absolute_path?(expanded_host) do
        raise Error, "#{where}: host must not contain symlink components"
      end

      env = normalize_cache_env!(Map.get(attrs, "env", %{}), where)
      max_size_mb = cache_max_size!(Map.get(attrs, "max_size_mb"), where)
      policy = normalize_cache_policy!(Map.get(attrs, "policy"), where)

      %CacheGroup{
        name: name,
        host: host,
        env: env,
        max_size_mb: max_size_mb,
        policy: policy
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_cache_env!(nil, _where), do: %{}

  defp normalize_cache_env!(%{} = env, where) do
    env = stringify_keys(env)

    Enum.each(env, fn {key, value} ->
      unless is_binary(value) do
        raise Error, "#{where}.env.#{key}: value must be a string"
      end

      unless key in @cache_env_allowlist do
        raise Error, "#{where}.env.#{key}: variable is not allowed for cache groups"
      end
    end)

    env
  end

  defp normalize_cache_env!(other, where) do
    raise Error, "#{where}.env must be a table, got #{type_name(other)}"
  end

  defp cache_max_size!(nil, _where), do: nil
  defp cache_max_size!(value, _where) when is_integer(value) and value > 0, do: value

  defp cache_max_size!(value, where) do
    raise Error, "#{where}.max_size_mb must be a positive integer, got #{inspect(value)}"
  end

  defp normalize_cache_policy!(nil, _where), do: nil

  defp normalize_cache_policy!(%{} = attrs, where) do
    attrs = stringify_keys(attrs)

    if Map.get(attrs, "mode") == "off" and Map.keys(attrs) -- ["mode"] != [] do
      raise Error, "#{where}.policy mode off cannot declare policy rules"
    end

    case Policy.parse(attrs, where: "#{where}.policy") do
      {:ok, policy} -> policy
      {:error, message} -> raise Error, message
    end
  end

  defp normalize_cache_policy!(other, where) do
    raise Error, "#{where}.policy must be a table, got #{type_name(other)}"
  end

  defp cache_root do
    (System.get_env("OMASHIKI_CACHE_ROOT") || Path.join(System.user_home!(), ".cache/omashiki"))
    |> Path.expand()
  end

  defp cache_path?(path) do
    relative = path |> Path.expand() |> Path.relative_to(cache_root())

    Path.type(relative) == :relative and relative != "." and relative != ".." and
      not String.starts_with?(relative, "../")
  end

  defp symlink_in_absolute_path?(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.any?(fn component ->
      match?({:ok, %File.Stat{type: :symlink}}, File.lstat(component))
    end)
  end

  defp build_credentials!(section) do
    credentials =
      section
      |> Enum.map(fn {name, attrs} ->
        where = "credentials.#{name}"
        attrs = require_table!(attrs, where)

        reject_unknown_fields!(
          attrs,
          ~w(provider model base_url api_key fallback_chain model_aliases),
          where
        )

        provider = require_string_field!(attrs, "provider", where)
        model = require_string_field!(attrs, "model", where)

        base_url =
          attrs
          |> optional_string_field!("base_url", where)
          |> resolve_env_reference!(where, "base_url")

        validate_credential_base_url!(base_url, where)

        api_key =
          (optional_string_field!(attrs, "api_key", where) || "")
          |> resolve_env_reference!(where, "api_key")

        fallback_chain = Map.get(attrs, "fallback_chain", [])
        model_aliases = Map.get(attrs, "model_aliases", %{})

        unless is_list(fallback_chain) and
                 Enum.all?(fallback_chain, &(is_binary(&1) and &1 != "")) do
          raise Error, "#{where}.fallback_chain must be an array of non-empty strings"
        end

        if length(fallback_chain) != length(Enum.uniq(fallback_chain)) do
          raise Error, "#{where}.fallback_chain must not contain duplicate names"
        end

        unless is_map(model_aliases) and
                 Enum.all?(model_aliases, fn {key, value} ->
                   is_binary(key) and is_binary(value)
                 end) do
          raise Error, "#{where}.model_aliases must be a string-to-string table"
        end

        %Credential{
          name: name,
          provider: provider,
          model: model,
          base_url: base_url,
          api_key: api_key,
          fallback_chain: fallback_chain,
          model_aliases: model_aliases
        }
      end)
      |> Enum.sort_by(& &1.name)

    validate_fallback_chains!(credentials)
    credentials
  end

  defp validate_fallback_chains!(credentials) do
    by_name = Map.new(credentials, &{&1.name, &1})

    Enum.each(credentials, fn credential ->
      Enum.each(credential.fallback_chain, fn fallback ->
        unless Map.has_key?(by_name, fallback) do
          raise Error,
                "credentials.#{credential.name}.fallback_chain: unknown credential #{inspect(fallback)}"
        end
      end)
    end)

    Enum.each(credentials, &validate_fallback_cycle!(&1.name, by_name, MapSet.new()))
  end

  defp validate_fallback_cycle!(name, by_name, visiting) do
    if MapSet.member?(visiting, name) do
      raise Error, "credentials.#{name}.fallback_chain contains a cycle"
    end

    visiting = MapSet.put(visiting, name)

    Enum.each(Map.fetch!(by_name, name).fallback_chain, fn fallback ->
      validate_fallback_cycle!(fallback, by_name, visiting)
    end)
  end

  # `api_key = "${env:VAR}"` keeps a live key in the operator's environment
  # instead of in this file, which is tracked by git. `base_url` takes the same
  # form so a private LAN address for a local model server stays out of the
  # tracked file too. Anything else is used verbatim, so existing plaintext
  # declarations keep working.
  @env_reference ~r/^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/

  defp resolve_env_reference!(nil, _where, _field), do: nil

  defp resolve_env_reference!(value, where, field) do
    case Regex.run(@env_reference, value) do
      [_, name] ->
        case System.get_env(name) do
          resolved when is_binary(resolved) and resolved != "" ->
            resolved

          _ ->
            raise Error,
                  "#{where}.#{field} references environment variable #{name}, which is unset or empty"
        end

      nil ->
        value
    end
  end

  defp validate_credential_base_url!(nil, _where), do: :ok

  defp validate_credential_base_url!(base_url, where) do
    uri = URI.parse(base_url)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      raise Error,
            "#{where}.base_url must be an HTTP URL without embedded credentials, query, or fragment"
    end
  end

  defp build_limits(section) when map_size(section) == 0, do: %{}

  defp build_limits(section) do
    section = stringify_keys(section)

    %{}
    |> maybe_put(
      :max_concurrent_containers,
      positive_int(Map.get(section, "max_concurrent_containers"))
    )
    |> maybe_put(:pids_limit, positive_int(Map.get(section, "pids_limit")))
    |> maybe_put(
      :global_budget_tokens,
      positive_int(Map.get(section, "global_budget_tokens"))
    )
    |> maybe_put(
      :global_budget_window_hours,
      positive_int(Map.get(section, "global_budget_window_hours"))
    )
    |> maybe_put(
      :nano_cpus,
      cpu_to_nano(Map.get(section, "cpu_per_container") || Map.get(section, "nano_cpus"))
    )
    |> maybe_put(
      :memory_bytes,
      memory_to_bytes(
        Map.get(section, "memory_per_container") || Map.get(section, "memory_bytes")
      )
    )
    |> maybe_put(
      :memory_swap_bytes,
      memory_to_bytes(Map.get(section, "memory_swap") || Map.get(section, "memory_swap_bytes"))
    )
    |> then(fn lim ->
      # Default swap == memory when only memory is set (matches HostSettings habit).
      cond do
        Map.has_key?(lim, :memory_bytes) and not Map.has_key?(lim, :memory_swap_bytes) ->
          Map.put(lim, :memory_swap_bytes, lim.memory_bytes)

        true ->
          lim
      end
    end)
  end

  defp require_table!(%{} = attrs, _where), do: stringify_keys(attrs)

  defp require_table!(other, where) do
    raise Error, "#{where}: expected a table, got #{type_name(other)}"
  end

  defp require_field!(attrs, field, where) when is_map(attrs) do
    case Map.get(attrs, field) do
      nil -> raise Error, "#{where}: missing required field #{inspect(field)}"
      "" -> raise Error, "#{where}: missing required field #{inspect(field)}"
      value -> value
    end
  end

  defp require_string_field!(attrs, field, where) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> value
      nil -> raise Error, "#{where}: missing required field #{inspect(field)}"
      _ -> raise Error, "#{where}.#{field} must be a non-empty string"
    end
  end

  defp optional_string_field!(attrs, field, where) do
    case Map.get(attrs, field) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      _ -> raise Error, "#{where}.#{field} must be a string"
    end
  end

  defp reject_unknown_fields!(attrs, allowed, where) do
    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> raise Error, "#{where}: unknown fields #{inspect(Enum.sort(unknown))}"
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
      {k, v} -> {to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp type_name(v) when is_binary(v), do: "string"
  defp type_name(v) when is_list(v), do: "array"
  defp type_name(v) when is_integer(v), do: "integer"
  defp type_name(v) when is_float(v), do: "float"
  defp type_name(v) when is_boolean(v), do: "boolean"
  defp type_name(v) when is_atom(v), do: "atom"
  defp type_name(v) when is_map(v), do: "table"
  defp type_name(_), do: "value"

  defp format_reason(reason), do: inspect(reason)

  defp positive_int(nil), do: nil
  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(n) when is_float(n) and n > 0, do: trunc(n)

  defp positive_int(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {i, _} when i > 0 -> i
      _ -> nil
    end
  end

  defp positive_int(_), do: nil

  defp cpu_to_nano(nil), do: nil
  defp cpu_to_nano(n) when is_integer(n) and n > 1_000_000, do: n
  defp cpu_to_nano(n) when is_integer(n) and n > 0, do: n * 1_000_000_000
  defp cpu_to_nano(n) when is_float(n) and n > 0, do: round(n * 1_000_000_000)

  defp cpu_to_nano(n) when is_binary(n) do
    case Float.parse(String.trim(n)) do
      {f, _} when f > 0 -> cpu_to_nano(f)
      _ -> nil
    end
  end

  defp cpu_to_nano(_), do: nil

  defp memory_to_bytes(nil), do: nil
  defp memory_to_bytes(n) when is_integer(n) and n > 0, do: n

  defp memory_to_bytes(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {n, rest} ->
        mult =
          case String.upcase(String.trim(rest)) do
            "" -> 1
            "B" -> 1
            "K" -> 1024
            "KB" -> 1024
            "M" -> 1024 ** 2
            "MB" -> 1024 ** 2
            "G" -> 1024 ** 3
            "GB" -> 1024 ** 3
            "T" -> 1024 ** 4
            "TB" -> 1024 ** 4
            _ -> nil
          end

        if mult, do: n * mult, else: nil

      :error ->
        nil
    end
  end

  defp memory_to_bytes(_), do: nil
  defp plugins_dir_for(base_dir) do
    direct = Path.join(base_dir, "plugins")
    if File.dir?(direct), do: direct, else: repo_plugins_dir()
  end

  defp repo_plugins_dir, do: Path.expand("../../../plugins", __DIR__)

  defp expand_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_path(path) when is_binary(path), do: path

  defp reject_legacy_sections!(map) do
    for key <- ["harnesses"], Map.has_key?(map, key) do
      raise Error, "omashiki.toml: unknown section #{inspect(key)}"
    end

    :ok
  end
end
