defmodule Omashiki.Config.Repository do
  @moduledoc """
  Immutable registered repository definition.

  Identity is `name` plus `remote` and `base_branch`. `path` is this machine's
  clone: an operator checkout, or a core-managed mirror under
  `~/.cache/omashiki/mirrors/<name>` when `remote` is set and `path` is omitted.

  `ssh_key` / `ssh_key_passphrase` are host-side fetch and push credentials.
  They never enter the agent container.
  """
  @derive {Inspect, except: [:ssh_key_passphrase]}
  @enforce_keys [:name, :path, :base_branch]
  defstruct [:name, :path, :base_branch, :remote, :ssh_key, :ssh_key_passphrase]
end

defmodule Omashiki.Config.Machine do
  @moduledoc """
  Immutable declared execution node.

  A node is one machine that runs attempts. The name is the whole declaration:
  it is what `job_attempts.machine_id` records, so "which machine ran this?" is
  answerable from the database. Per-node capacity and per-node Docker endpoint
  are declared by the phases that consume them, not here.
  """
  @enforce_keys [:name]
  defstruct [:name]
end

defmodule Omashiki.Config.Step do
  @moduledoc "Ordered, argv-only environment lifecycle step."
  @enforce_keys [:phase, :argv, :condition, :timeout_ms]
  defstruct [:phase, :argv, :condition, :timeout_ms]
end

defmodule Omashiki.Config.Mount do
  @moduledoc "Validated host-to-container mount."
  @enforce_keys [:source, :target, :read_only]
  defstruct [:source, :target, :read_only]
end

defmodule Omashiki.Config.Environment do
  @moduledoc "Immutable governed execution environment."
  @enforce_keys [
    :name,
    :preset,
    :isolation,
    :image,
    :sink,
    :executables,
    :credentials,
    :host_credentials,
    :capabilities,
    :mcp_servers,
    :pre_steps,
    :post_steps,
    :timeout_ms,
    :caches,
    :mounts,
    :policy,
    :network,
    :resources,
    :packages
  ]
  defstruct @enforce_keys
end

defmodule Omashiki.Config.ResolvedJob do
  @moduledoc "Repository and environment values captured at job admission."
  @enforce_keys [:environment, :digest]
  defstruct [:repository, :environment, :digest]
end

defmodule Omashiki.Config.Registry do
  @moduledoc false

  alias Omashiki.Config.{Environment, Error, Mount, Machine, Repository, Step}
  alias Omashiki.Plugin.ImageProvides
  alias Omashiki.SupplyChain.Policy

  @name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @branch ~r/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/
  @conditions ~w(always on_success on_failure)
  @networks ~w(none restricted host)
  @sinks ~w(git files none)
  @unsafe_executables ~w(
    sh bash dash zsh fish cmd powershell pwsh env xargs
    python python2 python3 node perl ruby php lua busybox make awk
  )
  @mount_roots ~w(/workspace /run/omashiki /omashiki-cache)
  @max_timeout_ms 24 * 60 * 60 * 1_000
  @max_memory_bytes 1024 * 1024 * 1024 * 1024
  @env_reference ~r/^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/

  def build!(
        repository_section,
        environment_section,
        preset_section,
        node_section,
        caches,
        credentials,
        host_credentials,
        base_dir,
        plugins
      ) do
    if symlink_in_absolute_path?(base_dir) do
      raise Error, "configuration root must not contain symlink components"
    end

    repositories = build_repositories!(repository_section, base_dir)
    presets = Omashiki.Presets.build!(preset_section, plugins)
    nodes = build_nodes!(node_section)

    environments =
      build_environments!(
        environment_section,
        presets,
        caches,
        credentials,
        host_credentials,
        base_dir
      )

    digest = digest(repositories, presets, environments)

    %{
      repositories: repositories,
      presets: presets,
      environments: environments,
      nodes: nodes,
      registry_digest: digest
    }
  end

  # Nodes are deliberately not hashed here.
  #
  # The digest pins what a job *does* — its repository, preset, and environment
  # — and is captured at admission so a later reload cannot move the ground under
  # an admitted job. The node list is not part of that: a job admitted while three
  # machines were declared executes identically once a fourth joins. Hashing it
  # would invalidate every in-flight job's digest on scale-out or on draining a
  # machine, which are routine operations, not configuration drift.
  #
  # It would also defeat the cross-node comparison it looks like it serves. With
  # no `[nodes]` section the single implicit node is named after *this* machine,
  # so two identically-configured hosts would hash differently and report a
  # divergence that does not exist. Divergence stays loud where it is actually
  # checkable: a machine absent from a declared `[nodes]` list fails config load
  # outright rather than claiming work under a node id nothing else knows about.
  def digest(repositories, presets, environments) do
    canonical = %{
      repositories: Enum.map(repositories, &digest_repository/1),
      presets: presets,
      environments: Enum.map(environments, &digest_environment/1)
    }

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp digest_repository(%Repository{} = repo) do
    %{name: repo.name, remote: repo.remote, base_branch: repo.base_branch}
  end

  # A node declares a name and nothing else today. The fields a distributed
  # deployment needs — per-node capacity, per-node Docker endpoint — are added by
  # the changes that read them; an option nothing consumes is a lie in the file.
  defp build_nodes!(section) do
    section
    |> require_section_table!("nodes")
    |> Enum.map(fn {name, attrs} ->
      where = "nodes.#{name}"
      validate_name!(name, where)
      attrs = require_table!(attrs, where)
      reject_unknown!(attrs, [], where)
      %Machine{name: name}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp build_repositories!(section, base_dir) do
    section
    |> require_section_table!("repositories")
    |> Enum.map(fn {name, attrs} ->
      where = "repositories.#{name}"
      validate_name!(name, where)
      attrs = require_table!(attrs, where)
      reject_unknown!(attrs, ~w(path base_branch remote ssh_key ssh_key_passphrase), where)
      remote = optional_remote!(attrs, where)
      path = repository_path!(attrs, name, remote, base_dir, where)
      ssh_key = optional_ssh_key!(attrs, remote, where)
      ssh_key_passphrase = optional_ssh_passphrase!(attrs, ssh_key, where)
      base_branch = require_string!(attrs, "base_branch", where)

      unless valid_branch?(base_branch) do
        raise Error, "#{where}.base_branch is not a safe Git branch"
      end

      %Repository{
        name: name,
        path: path,
        base_branch: base_branch,
        remote: remote,
        ssh_key: ssh_key,
        ssh_key_passphrase: ssh_key_passphrase
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp optional_remote!(attrs, where) do
    case Map.get(attrs, "remote") do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        unless valid_remote?(value), do: raise(Error, "#{where}.remote is not a safe Git remote")
        value

      _ ->
        raise Error, "#{where}.remote must be a non-empty string"
    end
  end

  # An `ext::` remote runs an arbitrary command on every fetch and push, and a
  # leading dash is read by git as an option rather than a location.
  defp valid_remote?(value) do
    String.valid?(value) and not String.contains?(value, [<<0>>, "\n", " "]) and
      not String.starts_with?(value, ["-", "ext::"])
  end

  defp repository_path!(attrs, name, remote, base_dir, where) do
    case Map.get(attrs, "path") do
      nil when is_binary(remote) ->
        path = default_mirror_path(name)
        validate_declared_path!(path, remote, base_dir, where)
        path

      nil ->
        raise Error, "#{where}: missing required field \"path\""

      value when is_binary(value) and value != "" ->
        path = resolve_path(value, base_dir)
        validate_declared_path!(path, remote, base_dir, where)
        path

      _ ->
        raise Error, "#{where}.path must be a non-empty string"
    end
  end

  defp default_mirror_path(name),
    do: Path.join(mirror_root(), name)

  defp mirror_root,
    do: Path.join([System.user_home!(), ".cache", "omashiki", "mirrors"])

  defp validate_declared_path!(path, remote, base_dir, where) do
    unless contained?(path, base_dir) or contained?(path, mirror_root()) do
      raise Error,
            "#{where}.path must stay inside the configuration root or #{mirror_root()}"
    end

    if symlink_in_absolute_path?(path) do
      raise Error, "#{where}.path must be a real, non-symlink path"
    end

    if is_nil(remote) do
      unless File.dir?(path) and valid_git_metadata?(path, base_dir) and
               not symlink_in_path?(path, base_dir) do
        raise Error, "#{where}.path must be a real, non-symlink Git repository"
      end
    else
      if File.exists?(path) do
        unless File.dir?(path) and valid_git_metadata?(path, base_dir) do
          raise Error, "#{where}.path must be a real, non-symlink directory"
        end
      end
    end
  end

  defp optional_ssh_key!(attrs, remote, where) do
    case Map.get(attrs, "ssh_key") do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        unless is_binary(remote) do
          raise Error, "#{where}.ssh_key requires remote"
        end

        path = expand_host_path(value)

        unless Path.type(path) == :absolute do
          raise Error, "#{where}.ssh_key must resolve to an absolute host path"
        end

        unless String.printable?(path) and
                 not String.contains?(path, [
                   <<0>>,
                   "\n",
                   "\r",
                   "\t",
                   " ",
                   "'",
                   "\"",
                   ";",
                   "|",
                   "&",
                   "$",
                   "`",
                   "<",
                   ">",
                   "(",
                   ")",
                   "{",
                   "}",
                   "[",
                   "]",
                   "*",
                   "?",
                   "!",
                   "\\"
                 ]) do
          raise Error, "#{where}.ssh_key is not a safe host path"
        end

        path

      _ ->
        raise Error, "#{where}.ssh_key must be a non-empty string"
    end
  end

  defp optional_ssh_passphrase!(attrs, ssh_key, where) do
    case Map.get(attrs, "ssh_key_passphrase") do
      nil ->
        nil

      value when is_binary(value) ->
        unless is_binary(ssh_key) do
          raise Error, "#{where}.ssh_key_passphrase requires ssh_key"
        end

        unless Regex.match?(@env_reference, value) do
          raise Error,
                "#{where}.ssh_key_passphrase must be an environment reference ${env:VAR}"
        end

        value

      _ ->
        raise Error, "#{where}.ssh_key_passphrase must be a string"
    end
  end

  defp expand_host_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_host_path(path), do: Path.expand(path)

  defp build_environments!(section, presets, caches, credentials, host_credentials, base_dir) do
    presets_by_name = Map.new(presets, &{&1.name, &1})
    caches_by_name = Map.new(caches, &{&1.name, &1})
    credentials_by_name = Map.new(credentials, &{&1.name, &1})
    host_credentials_by_name = Map.new(host_credentials, &{&1.name, &1})

    shared =
      credentials_by_name
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(host_credentials_by_name, &1))

    if shared != [] do
      raise Error, "credential names #{inspect(Enum.sort(shared))} are declared twice"
    end

    section
    |> require_section_table!("environments")
    |> Enum.map(fn {name, attrs} ->
      where = "environments.#{name}"
      validate_name!(name, where)
      attrs = require_table!(attrs, where)

      if Map.has_key?(attrs, "harness") do
        raise Error, "#{where}: unknown field \"harness\""
      end

      reject_unknown!(
        attrs,
        ~w(preset isolation image sink packages executables credentials capabilities mcp_servers pre_steps post_steps timeout_ms caches mounts policy network resources),
        where
      )

      timeout_ms = positive_integer!(attrs, "timeout_ms", where, @max_timeout_ms)
      preset_name = require_string!(attrs, "preset", where)
      isolation = require_string!(attrs, "isolation", where)
      image = require_string!(attrs, "image", where)
      sink = require_string!(attrs, "sink", where)
      packages = packages_list!(attrs, "packages", where)

      if packages == nil do
        raise Error, "#{where}.packages is required (use an empty list to declare none)"
      end

      unless sink in @sinks,
        do: raise(Error, "#{where}.sink must be one of #{Enum.join(@sinks, ", ")}")

      executables = string_list!(attrs, "executables", where)

      if executables == [], do: raise(Error, "#{where}.executables must not be empty")

      if Enum.any?(executables, &(Path.basename(&1) in @unsafe_executables)) do
        raise Error, "#{where}.executables contains an unsafe executable"
      end

      base_preset =
        case Map.get(presets_by_name, preset_name) do
          nil -> raise Error, "#{where}.preset references unknown preset #{inspect(preset_name)}"
          profile -> profile
        end

      preset = Omashiki.Presets.finalize_preset!(base_preset, isolation, image, where)

      validate_requires!(preset.manifest, image, packages, where)

      {resolved_credentials, resolved_host_credentials} =
        attrs
        |> credential_names!(where)
        |> split_credentials!(credentials_by_name, host_credentials_by_name, where)

      resolved_credentials = expand_credentials(resolved_credentials, credentials_by_name)

      capabilities = optional_string_list!(attrs, "capabilities", where)
      mcp_servers = mcp_servers!(Map.get(attrs, "mcp_servers", %{}), where)

      resolved_caches = resolve_names!(attrs, "caches", caches_by_name, where, "cache")

      pre_steps =
        build_steps!(Map.get(attrs, "pre_steps", []), :pre, timeout_ms, executables, where)

      post_steps =
        build_steps!(Map.get(attrs, "post_steps", []), :post, timeout_ms, executables, where)

      mounts = build_mounts!(Map.get(attrs, "mounts", []), base_dir, where)
      policy = build_policy!(Map.get(attrs, "policy", %{"mode" => "off"}), where)
      network = Map.get(attrs, "network", "none")

      unless network in @networks,
        do: raise(Error, "#{where}.network must be one of #{Enum.join(@networks, ", ")}")

      if policy.mode == :allowlist and network != "restricted" do
        raise Error, "#{where}: allowlist policy requires restricted network"
      end

      %Environment{
        name: name,
        preset: preset,
        isolation: isolation,
        image: image,
        sink: sink,
        packages: packages,
        executables: executables,
        credentials: resolved_credentials,
        host_credentials: resolved_host_credentials,
        capabilities: capabilities,
        mcp_servers: mcp_servers,
        pre_steps: pre_steps,
        post_steps: post_steps,
        timeout_ms: timeout_ms,
        caches: resolved_caches,
        mounts: mounts,
        policy: policy,
        network: network,
        resources: build_resources!(Map.get(attrs, "resources", %{}), where)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp build_steps!(steps, phase, environment_timeout_ms, executables, where)
       when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {attrs, index} ->
      step_where = "#{where}.#{phase}_steps[#{index}]"
      attrs = require_table!(attrs, step_where)
      reject_unknown!(attrs, ~w(argv condition timeout_ms), step_where)
      argv = Map.get(attrs, "argv")

      unless is_list(argv) and argv != [] and Enum.all?(argv, &valid_arg?/1) do
        raise Error, "#{step_where}.argv must be a non-empty array of safe strings"
      end

      executable = argv |> hd() |> Path.basename()

      if executable in @unsafe_executables do
        raise Error, "#{step_where}.argv uses unsafe executable #{inspect(executable)}"
      end

      unless hd(argv) in executables do
        raise Error, "#{step_where}.argv executable #{inspect(hd(argv))} is not declared"
      end

      condition = Map.get(attrs, "condition", "always")

      unless condition in @conditions do
        raise Error, "#{step_where}.condition must be one of #{Enum.join(@conditions, ", ")}"
      end

      timeout_ms =
        case Map.fetch(attrs, "timeout_ms") do
          {:ok, _} -> positive_integer!(attrs, "timeout_ms", step_where, environment_timeout_ms)
          :error -> environment_timeout_ms
        end

      %Step{phase: phase, argv: argv, condition: condition, timeout_ms: timeout_ms}
    end)
  end

  defp build_steps!(_, phase, _timeout, _executables, where),
    do: raise(Error, "#{where}.#{phase}_steps must be an array")

  defp build_mounts!(mounts, base_dir, where) when is_list(mounts) do
    parsed =
      mounts
      |> Enum.with_index()
      |> Enum.map(fn {attrs, index} ->
        mount_where = "#{where}.mounts[#{index}]"
        attrs = require_table!(attrs, mount_where)
        reject_unknown!(attrs, ~w(source target read_only), mount_where)
        source = attrs |> require_string!("source", mount_where) |> resolve_path(base_dir)
        target = require_string!(attrs, "target", mount_where)
        read_only = Map.get(attrs, "read_only", true)

        unless contained?(source, base_dir) do
          raise Error, "#{mount_where}.source must stay inside the configuration root"
        end

        unless File.exists?(source) and not symlink_in_path?(source, base_dir),
          do: raise(Error, "#{mount_where}.source must exist without symlink components")

        unless Path.type(target) == :absolute and governed_target?(target),
          do: raise(Error, "#{mount_where}.target must be inside a governed container root")

        unless is_boolean(read_only),
          do: raise(Error, "#{mount_where}.read_only must be a boolean")

        if read_only == false and
             not String.starts_with?(Path.expand(target), "/run/omashiki/state/") do
          raise Error,
                "#{mount_where} writable mounts must target the managed /run/omashiki/state root"
        end

        %Mount{source: source, target: Path.expand(target), read_only: read_only}
      end)

    targets = Enum.map(parsed, & &1.target)

    if length(targets) != length(Enum.uniq(targets)),
      do: raise(Error, "#{where}.mounts contains duplicate targets")

    parsed
  end

  defp build_mounts!(_, _base_dir, where), do: raise(Error, "#{where}.mounts must be an array")

  defp mcp_servers!(servers, where) when is_map(servers) do
    Enum.reduce(servers, %{}, fn {name, attrs}, acc ->
      unless is_binary(name) and name != "" and
               name not in ["omakiten", "planning", "public-planning"],
             do: raise(Error, "#{where}.mcp_servers contains a public planning server")

      attrs = require_table!(attrs, "#{where}.mcp_servers.#{name}")
      reject_unknown!(attrs, ~w(url headers), "#{where}.mcp_servers.#{name}")
      url = require_string!(attrs, "url", "#{where}.mcp_servers.#{name}")
      uri = URI.parse(url)

      unless uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "",
        do: raise(Error, "#{where}.mcp_servers.#{name}.url must be an absolute URL")

      headers = Map.get(attrs, "headers", %{})

      unless is_map(headers) and
               Enum.all?(headers, fn {key, value} ->
                 is_binary(to_string(key)) and is_binary(to_string(value))
               end),
             do: raise(Error, "#{where}.mcp_servers.#{name}.headers must be a table")

      Map.put(acc, name, %{"url" => url, "headers" => stringify_map(headers)})
    end)
  end

  defp mcp_servers!(_, where), do: raise(Error, "#{where}.mcp_servers must be a table")

  defp stringify_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp build_resources!(attrs, where) do
    attrs = require_table!(attrs, "#{where}.resources")
    reject_unknown!(attrs, ~w(cpus memory memory_swap pids), "#{where}.resources")

    nano_cpus = cpu!(Map.get(attrs, "cpus"), where)
    memory_bytes = memory!(Map.get(attrs, "memory"), where, "memory")
    memory_swap_bytes = memory!(Map.get(attrs, "memory_swap"), where, "memory_swap", memory_bytes)
    pids_limit = integer!(Map.get(attrs, "pids"), where, "pids", 32, 4096)

    if memory_swap_bytes < memory_bytes,
      do: raise(Error, "#{where}.resources.memory_swap must not be below memory")

    %{
      nano_cpus: nano_cpus,
      memory_bytes: memory_bytes,
      memory_swap_bytes: memory_swap_bytes,
      pids_limit: pids_limit
    }
  end

  defp build_policy!(attrs, where) do
    attrs = require_table!(attrs, "#{where}.policy")

    if Map.get(attrs, "mode") == "off" and Map.keys(attrs) -- ["mode"] != [] do
      raise Error, "#{where}.policy mode off cannot declare policy rules"
    end

    case Policy.parse(attrs, where: "#{where}.policy") do
      {:ok, policy} -> policy
      {:error, message} -> raise Error, message
    end
  end

  defp resolve_names!(attrs, key, known, where, kind) do
    values = Map.get(attrs, key, [])

    unless is_list(values) and Enum.all?(values, &is_binary/1) do
      raise Error, "#{where}.#{key} must be an array of names"
    end

    if length(values) != length(Enum.uniq(values)) do
      raise Error, "#{where}.#{key} must not contain duplicate names"
    end

    Enum.map(values, fn name ->
      Map.get(known, name) || raise(Error, "#{where}.#{key}: unknown #{kind} #{inspect(name)}")
    end)
  end

  # One declared list, two resolved kinds: LLM gateway credentials keep feeding
  # the gateway, host credentials are materialized per attempt.
  defp credential_names!(attrs, where) do
    values = Map.get(attrs, "credentials", [])

    unless is_list(values) and Enum.all?(values, &is_binary/1) do
      raise Error, "#{where}.credentials must be an array of names"
    end

    if length(values) != length(Enum.uniq(values)) do
      raise Error, "#{where}.credentials must not contain duplicate names"
    end

    values
  end

  defp split_credentials!(names, by_name, host_by_name, where) do
    Enum.reduce(names, {[], []}, fn name, {credentials, host_credentials} ->
      cond do
        credential = Map.get(by_name, name) ->
          {[credential | credentials], host_credentials}

        host_credential = Map.get(host_by_name, name) ->
          {credentials, [host_credential | host_credentials]}

        true ->
          raise Error, "#{where}.credentials: unknown credential #{inspect(name)}"
      end
    end)
    |> then(fn {credentials, host_credentials} ->
      {Enum.reverse(credentials), Enum.reverse(host_credentials)}
    end)
  end

  defp expand_credentials(credentials, by_name) do
    {expanded, _seen} =
      Enum.reduce(credentials, {[], MapSet.new()}, fn credential, acc ->
        expand_credential(credential, by_name, acc)
      end)

    Enum.reverse(expanded)
  end

  defp expand_credential(credential, by_name, {expanded, seen}) do
    if MapSet.member?(seen, credential.name) do
      {expanded, seen}
    else
      Enum.reduce(
        credential.fallback_chain,
        {[credential | expanded], MapSet.put(seen, credential.name)},
        fn fallback, acc -> expand_credential(Map.fetch!(by_name, fallback), by_name, acc) end
      )
    end
  end

  defp validate_requires!(
         %Omashiki.Plugin.Manifest{requires: %{"binaries" => required}},
         image,
         packages,
         where
       )
       when is_list(required) and is_binary(image) and is_list(packages) do
    ImageProvides.cover!(image, required, packages, where)
  end

  defp validate_requires!(_manifest, _image, _packages, where) do
    raise Error, "#{where}: preset plugin manifest missing for requires check"
  end

  defp digest_environment(environment) do
    environment
    |> Map.from_struct()
    |> Map.update!(:credentials, fn credentials ->
      Enum.map(credentials, fn credential ->
        credential |> Map.from_struct() |> Map.delete(:api_key)
      end)
    end)
  end

  defp positive_integer!(attrs, key, where, max) do
    value = Map.get(attrs, key)

    unless is_integer(value) and value > 0 and value <= max,
      do: raise(Error, "#{where}.#{key} must be between 1 and #{max}")

    value
  end

  defp cpu!(value, _where) when is_integer(value) and value > 0 and value <= 64,
    do: value * 1_000_000_000

  defp cpu!(value, where) when is_float(value) and value > 0 and value <= 64 do
    case round(value * 1_000_000_000) do
      nano_cpus when nano_cpus > 0 -> nano_cpus
      _ -> raise Error, "#{where}.resources.cpus must resolve to at least one nano-CPU"
    end
  end

  defp cpu!(_, where), do: raise(Error, "#{where}.resources.cpus must be between 1 and 64")

  defp memory!(value, where, key, default \\ nil)

  defp memory!(nil, _where, _key, default) when is_integer(default), do: default

  defp memory!(value, where, key, _default) do
    case parse_memory(value) do
      bytes when is_integer(bytes) and bytes > 0 and bytes <= @max_memory_bytes -> bytes
      _ -> raise Error, "#{where}.resources.#{key} must be between 1 byte and 1 TB"
    end
  end

  defp parse_memory(value) when is_integer(value), do: value

  defp parse_memory(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+)\s*(B|KB|MB|GB)?\z/i, value, capture: :all_but_first) do
      [number, unit] -> String.to_integer(number) * memory_multiplier(String.upcase(unit))
      [number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp parse_memory(_), do: nil
  defp memory_multiplier(""), do: 1
  defp memory_multiplier("B"), do: 1
  defp memory_multiplier("KB"), do: 1024
  defp memory_multiplier("MB"), do: 1024 * 1024
  defp memory_multiplier("GB"), do: 1024 * 1024 * 1024

  defp integer!(value, _where, _key, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: value

  defp integer!(_value, where, key, min, max),
    do: raise(Error, "#{where}.resources.#{key} must be between #{min} and #{max}")

  defp require_section_table!(section, _name) when is_map(section), do: section
  defp require_section_table!(_, name), do: raise(Error, "[#{name}] must be a table")

  defp require_table!(attrs, _where) when is_map(attrs), do: stringify_keys(attrs)
  defp require_table!(_, where), do: raise(Error, "#{where} must be a table")

  defp require_string!(attrs, key, where) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise Error, "#{where}: missing required field #{inspect(key)}"
    end
  end

  defp string_list!(attrs, key, where) do
    case Map.get(attrs, key) do
      values when is_list(values) ->
        if values != [] and Enum.all?(values, &(is_binary(&1) and &1 != "")) and
             length(values) == length(Enum.uniq(values)) do
          values
        else
          raise Error, "#{where}.#{key} must be a unique array of non-empty strings"
        end

      _ ->
        raise Error, "#{where}.#{key} must be an array"
    end
  end

  defp packages_list!(attrs, key, where) do
    case Map.get(attrs, key) do
      [] ->
        []

      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")) and
             length(values) == length(Enum.uniq(values)) do
          values
        else
          raise Error, "#{where}.#{key} must be a unique array of non-empty strings"
        end

      nil ->
        nil

      _ ->
        raise Error, "#{where}.#{key} must be an array"
    end
  end

  defp optional_string_list!(attrs, key, where) do
    case Map.get(attrs, key, []) do
      values when is_list(values) ->
        cond do
          not Enum.all?(values, &(is_binary(&1) and &1 != "")) ->
            raise Error, "#{where}.#{key} must be an array of strings"

          length(values) != length(Enum.uniq(values)) ->
            raise Error, "#{where}.#{key} must not contain duplicates"

          true ->
            values
        end

      _ ->
        raise Error, "#{where}.#{key} must be an array of strings"
    end
  end

  defp reject_unknown!(attrs, allowed, where) do
    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> raise Error, "#{where}: unknown fields #{inspect(Enum.sort(unknown))}"
    end
  end

  defp validate_name!(name, where) do
    unless is_binary(name) and Regex.match?(@name, name),
      do: raise(Error, "#{where} name must be kebab-case")
  end

  def valid_branch?(branch) when is_binary(branch) do
    Regex.match?(@branch, branch) and not String.contains?(branch, ["..", "@{", "//"]) and
      not String.ends_with?(branch, [".", "/"]) and
      not Enum.any?(Path.split(branch), &String.ends_with?(&1, ".lock")) and
      not String.contains?(branch, "/.") and git_branch?(branch)
  end

  def valid_branch?(_), do: false

  defp git_branch?(branch) do
    match?(
      {_output, 0},
      System.cmd("git", ["check-ref-format", "--branch", branch], stderr_to_stdout: true)
    )
  rescue
    ErlangError -> false
  end

  defp valid_arg?(arg) do
    is_binary(arg) and arg != "" and String.valid?(arg) and not String.contains?(arg, <<0>>)
  end

  defp governed_target?(target) do
    expanded = Path.expand(target)
    Enum.any?(@mount_roots, &(expanded == &1 or String.starts_with?(expanded, &1 <> "/")))
  end

  defp resolve_path("~/" <> rest, _base_dir), do: Path.join(System.user_home!(), rest)
  defp resolve_path(path, base_dir), do: Path.expand(path, base_dir)

  defp contained?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp symlink_in_path?(path, root) do
    relative = Path.relative_to(path, root)

    relative
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(fn component ->
      match?({:ok, %File.Stat{type: :symlink}}, File.lstat(component))
    end)
  end

  defp valid_git_metadata?(path, _base_dir) do
    git_path = Path.join(path, ".git")

    git_repository?(path) and
      case File.lstat(git_path) do
        {:ok, %File.Stat{type: :directory}} ->
          valid_common_gitdir?(git_path)

        {:ok, %File.Stat{type: :regular}} ->
          case File.read(git_path) do
            {:ok, "gitdir: " <> target} ->
              target = Path.expand(String.trim(target), path)

              directory?(target) and not symlink_in_absolute_path?(target) and
                linked_worktree_gitdir?(target, git_path)

            _ ->
              false
          end

        _ ->
          false
      end
  end

  defp git_repository?(path) do
    match?(
      {"true\n", 0},
      System.cmd("git", ["-C", path, "rev-parse", "--is-inside-work-tree"],
        stderr_to_stdout: true
      )
    )
  rescue
    ErlangError -> false
  end

  defp linked_worktree_gitdir?(target, git_path) do
    backlink = Path.join(target, "gitdir")
    commondir_path = Path.join(target, "commondir")

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(backlink),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(commondir_path),
         {:ok, backlink_value} <- File.read(backlink),
         {:ok, commondir_value} <- File.read(commondir_path) do
      common_dir = Path.expand(String.trim(commondir_value), target)

      Path.expand(String.trim(backlink_value), target) == git_path and
        Path.basename(Path.dirname(target)) == "worktrees" and
        Path.dirname(Path.dirname(target)) == common_dir and
        not symlink_in_absolute_path?(common_dir) and valid_common_gitdir?(common_dir)
    else
      _ -> false
    end
  end

  defp valid_common_gitdir?(path) do
    regular_file?(Path.join(path, "HEAD")) and directory?(Path.join(path, "objects")) and
      directory?(Path.join(path, "refs")) and not symlink_in_absolute_path?(path)
  end

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
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

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
