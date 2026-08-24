defmodule Omashiki.SupplyChain.Registry do
  @moduledoc "A named, operator-declared HTTPS registry."

  defstruct [:name, :url, :download_url, :credential_env]
end

defmodule Omashiki.SupplyChain.GitSource do
  @moduledoc "An HTTPS Git source pinned to one full immutable commit."

  defstruct [:url, :commit]
end

defmodule Omashiki.SupplyChain.DirectSource do
  @moduledoc "An HTTPS archive or package URL pinned by SHA-256."

  defstruct [:url, :sha256]
end

defmodule Omashiki.SupplyChain.Policy do
  @moduledoc "Normalized, fail-closed supply-chain policy for one cache group."

  alias Omashiki.SupplyChain.{DirectSource, GitSource, Paths, Registry}

  @modes ~w(off audit allowlist)
  @ecosystems ~w(npm cargo go)
  @name ~r/^[A-Za-z0-9._@\/-]+(?:\*)?$/
  @constraint ~r/^v?\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?(?:\.\*)?$/
  @commit ~r/^[0-9a-fA-F]{40}$/
  @sha256 ~r/^[0-9a-fA-F]{64}$/
  @env_name ~r/^[A-Z_][A-Z0-9_]*$/

  defstruct mode: nil,
            registries: %{},
            packages: %{},
            package_registries: %{},
            git: [],
            direct_urls: [],
            local_roots: [],
            digest: nil

  def modes, do: @modes
  def ecosystems, do: @ecosystems

  @doc "Parse and normalize one policy table without raising."
  def parse(attrs, opts \\ [])

  def parse(attrs, opts) when is_map(attrs) do
    where = Keyword.get(opts, :where, "policy")
    attrs = stringify_keys(attrs)

    with :ok <-
           reject_unknown_keys(
             attrs,
             ~w(mode registries packages git direct_urls local_roots),
             where
           ),
         {:ok, mode} <- mode(Map.get(attrs, "mode"), where),
         {:ok, registries} <- registries(Map.get(attrs, "registries", %{}), where),
         {:ok, {packages, package_registries}} <-
           packages(Map.get(attrs, "packages", %{}), where),
         {:ok, git} <- git_sources(Map.get(attrs, "git", []), where),
         {:ok, direct_urls} <- direct_sources(Map.get(attrs, "direct_urls", []), where),
         {:ok, local_roots} <- local_roots(Map.get(attrs, "local_roots", []), where),
         :ok <- mode_conflicts(mode, packages, where) do
      policy = %__MODULE__{
        mode: mode,
        registries: registries,
        packages: packages,
        package_registries: package_registries,
        git: git,
        direct_urls: direct_urls,
        local_roots: local_roots
      }

      {:ok, %{policy | digest: digest(policy)}}
    end
  end

  def parse(_, opts), do: {:error, "#{Keyword.get(opts, :where, "policy")} must be a table"}

  def parse!(attrs, opts \\ []) do
    case parse(attrs, opts) do
      {:ok, policy} -> policy
      {:error, message} -> raise Omashiki.SupplyChain.Error, message
    end
  end

  @doc "Stable SHA-256 partition key for a normalized policy."
  def digest(%__MODULE__{} = policy) do
    policy
    |> Map.from_struct()
    |> Map.delete(:digest)
    |> :erlang.term_to_binary([:compressed])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Return whether a version satisfies an exact or trailing-wildcard constraint."
  def version_allowed?(version, constraint)
      when is_binary(version) and is_binary(constraint) do
    cond do
      String.ends_with?(constraint, ".*") ->
        prefix = String.trim_trailing(constraint, ".*")
        version == prefix or String.starts_with?(version, prefix <> ".")

      true ->
        version == constraint
    end
  end

  def version_allowed?(_, _), do: false

  @doc "Find the package constraint and optional registry name for a dependency."
  def package_rule(%__MODULE__{} = policy, ecosystem, name) do
    rules = Map.get(policy.packages, ecosystem, %{})

    Enum.find_value(rules, fn {pattern, constraint} ->
      if package_name_allowed?(name, pattern),
        do: {constraint, registry_name(policy, ecosystem, pattern)}
    end)
  end

  @doc "Return named registries for an ecosystem in deterministic order."
  def registries_for(%__MODULE__{} = policy, ecosystem) do
    policy.registries
    |> Map.get(ecosystem, %{})
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc "Select a declared registry, optionally by name or matching source URL."
  def select_registry(%__MODULE__{} = policy, ecosystem, opts \\ []) do
    requested = Keyword.get(opts, :name)
    source_url = Keyword.get(opts, :source_url)
    registries = registries_for(policy, ecosystem)

    if is_nil(requested) and is_nil(source_url) and length(registries) != 1 do
      nil
    else
      Enum.find(registries, fn registry ->
        (is_nil(requested) or registry.name == requested) and
          (is_nil(source_url) or registry_url_matches?(registry.url, source_url))
      end)
    end
  end

  @doc "Evaluate one normalized dependency and fail closed on ambiguity."
  def authorize(%__MODULE__{mode: :off}, dependency) when is_map(dependency),
    do: {:allow, "policy is off"}

  def authorize(%__MODULE__{} = policy, dependency) when is_map(dependency) do
    ecosystem = value(dependency, :ecosystem)
    source = value(dependency, :source)

    case source do
      :registry -> authorize_registry(policy, ecosystem, dependency)
      :git -> authorize_git(policy, dependency)
      :direct_url -> authorize_direct(policy, dependency)
      :local -> authorize_local(policy, dependency)
      _ -> {:deny, "unknown dependency source"}
    end
  end

  def authorize(_, _), do: {:deny, "invalid dependency"}

  defp authorize_registry(policy, ecosystem, dependency) do
    name = value(dependency, :name)
    version = value(dependency, :version)
    source_url = value(dependency, :source_url)
    package_rule = package_rule(policy, ecosystem, name)
    package_registry = package_rule && elem(package_rule, 1)
    requested_registry = value(dependency, :registry)
    registry_name = requested_registry || package_registry
    registry = select_registry(policy, ecosystem, name: registry_name, source_url: source_url)

    cond do
      ecosystem not in @ecosystems ->
        {:deny, "unknown ecosystem #{inspect(ecosystem)}"}

      not is_binary(name) or name == "" ->
        {:deny, "package name is missing"}

      is_binary(requested_registry) and is_binary(package_registry) and
          requested_registry != package_registry ->
        {:deny, "registry for #{ecosystem}/#{name} is not allowlisted"}

      is_nil(registry) ->
        {:deny, "registry for #{ecosystem}/#{name} is not declared"}

      policy.mode == :off ->
        {:allow, "policy is off; declared registry is explicit"}

      not is_binary(version) or version == "" ->
        {:deny, "package #{name} has no immutable version"}

      is_nil(package_rule) ->
        {:deny, "package #{ecosystem}/#{name} is not allowlisted"}

      not version_allowed?(version, elem(package_rule, 0)) ->
        {:deny,
         "package #{ecosystem}/#{name} version #{version} does not match " <>
           elem(package_rule, 0)}

      true ->
        {:allow, "package and registry are allowlisted"}
    end
  end

  defp authorize_git(policy, dependency) do
    url = value(dependency, :source_url)
    commit = value(dependency, :commit)

    if Enum.any?(policy.git, &(&1.url == url and &1.commit == commit)) do
      {:allow, "Git URL and commit are allowlisted"}
    else
      {:deny, "Git URL and immutable commit are not allowlisted"}
    end
  end

  defp authorize_direct(policy, dependency) do
    url = value(dependency, :source_url)
    sha256 = value(dependency, :sha256)

    if Enum.any?(policy.direct_urls, &(&1.url == url and &1.sha256 == sha256)) do
      {:allow, "direct URL and SHA-256 are allowlisted"}
    else
      {:deny, "direct URL and SHA-256 are not allowlisted"}
    end
  end

  defp authorize_local(policy, dependency) do
    path = value(dependency, :path)

    if is_binary(path) and Enum.any?(policy.local_roots, &local_contained?(path, &1)) do
      {:allow, "local source is inside an allowlisted root"}
    else
      {:deny, "local source is outside allowlisted roots or is not real"}
    end
  end

  defp mode(nil, where), do: {:error, "#{where}: missing required field \"mode\""}
  defp mode(mode, _where) when mode in @modes, do: {:ok, String.to_atom(mode)}
  defp mode(mode, where), do: {:error, "#{where}.mode: unknown mode #{inspect(mode)}"}

  defp registries(nil, _where), do: {:ok, %{}}

  defp registries(%{} = raw, where) do
    raw = stringify_keys(raw)

    with :ok <- validate_names(Map.keys(raw), @ecosystems, "ecosystem", where),
         {:ok, result} <- parse_registry_ecosystems(raw, where) do
      {:ok, result}
    end
  end

  defp registries(other, where),
    do: {:error, "#{where}.registries must be a table, got #{type_name(other)}"}

  defp parse_registry_ecosystems(raw, where) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {ecosystem, entries}, {:ok, acc} ->
      entries = if is_map(entries), do: stringify_keys(entries), else: entries

      with true <- is_map(entries),
           {:ok, parsed} <- parse_registry_entries(entries, ecosystem, where),
           :ok <- reject_registry_conflicts(parsed, ecosystem, where) do
        {:cont, {:ok, Map.put(acc, ecosystem, parsed)}}
      else
        false -> {:halt, {:error, "#{where}.registries.#{ecosystem} must be a table"}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp parse_registry_entries(entries, ecosystem, where) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {name, attrs}, {:ok, acc} ->
      attrs = if is_map(attrs), do: stringify_keys(attrs), else: attrs
      registry_where = "#{where}.registries.#{ecosystem}.#{name}"

      with true <- is_binary(name) and Regex.match?(@name, name) and name != "",
           true <- is_map(attrs),
           :ok <- reject_unknown_keys(attrs, ~w(url download_url credential_env), registry_where),
           {:ok, url} <- secure_url(Map.get(attrs, "url"), registry_where),
           {:ok, download_url} <-
             optional_secure_url(Map.get(attrs, "download_url"), registry_where),
           {:ok, credential_env} <-
             credential_env(Map.get(attrs, "credential_env"), registry_where) do
        registry = %Registry{
          name: name,
          url: url,
          download_url: download_url,
          credential_env: credential_env
        }

        {:cont, {:ok, Map.put(acc, name, registry)}}
      else
        false -> {:halt, {:error, "#{registry_where} must be a named table with a valid name"}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp reject_registry_conflicts(registries, ecosystem, where) do
    urls = registries |> Map.values() |> Enum.map(& &1.url)

    if length(urls) == length(Enum.uniq(urls)) do
      :ok
    else
      {:error, "#{where}.registries.#{ecosystem}: registry URLs conflict and must be unique"}
    end
  end

  defp packages(nil, _where), do: {:ok, {%{}, %{}}}

  defp packages(%{} = raw, where) do
    raw = stringify_keys(raw)

    with :ok <- validate_names(Map.keys(raw), @ecosystems, "ecosystem", "#{where}.packages"),
         {:ok, result} <- parse_package_ecosystems(raw, where) do
      {:ok, result}
    end
  end

  defp packages(other, where),
    do: {:error, "#{where}.packages must be a table, got #{type_name(other)}"}

  defp parse_package_ecosystems(raw, where) do
    Enum.reduce_while(raw, {:ok, {%{}, %{}}}, fn {ecosystem, entries},
                                                 {:ok, {packages, registries}} ->
      if is_map(entries) do
        case parse_package_entries(stringify_keys(entries), ecosystem, where) do
          {:ok, {parsed, parsed_registries}} ->
            {:cont,
             {:ok,
              {Map.put(packages, ecosystem, parsed),
               Map.put(registries, ecosystem, parsed_registries)}}}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      else
        {:halt, {:error, "#{where}.packages.#{ecosystem} must be a table"}}
      end
    end)
  end

  defp parse_package_entries(entries, ecosystem, where) do
    Enum.reduce_while(entries, {:ok, {%{}, %{}}}, fn {pattern, raw}, {:ok, {acc, registry_acc}} ->
      package_where = "#{where}.packages.#{ecosystem}.#{pattern}"
      {constraint, registry} = package_constraint(raw)

      cond do
        not is_binary(pattern) or pattern == "" or not Regex.match?(@name, pattern) ->
          {:halt, {:error, "#{package_where}: package name pattern is invalid"}}

        not is_binary(constraint) or not Regex.match?(@constraint, constraint) ->
          {:halt,
           {:error,
            "#{package_where}: unsupported version constraint #{inspect(constraint)}; only exact versions and trailing .* wildcards are supported"}}

        is_binary(registry) and registry == "" ->
          {:halt, {:error, "#{package_where}.registry must be a non-empty string"}}

        true ->
          {:cont,
           {:ok, {Map.put(acc, pattern, constraint), maybe_put(registry_acc, pattern, registry)}}}
      end
    end)
  end

  defp package_constraint(value) when is_binary(value), do: {value, nil}

  defp package_constraint(%{} = value) do
    value = stringify_keys(value)
    {Map.get(value, "version") || Map.get(value, "constraint"), Map.get(value, "registry")}
  end

  defp package_constraint(_), do: {nil, nil}

  defp git_sources(nil, _where), do: {:ok, []}

  defp git_sources(raw, where) when is_list(raw) do
    raw
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      source_where = "#{where}.git[#{index}]"

      with true <- is_map(entry),
           entry <- stringify_keys(entry),
           :ok <- reject_unknown_keys(entry, ~w(url commit), source_where),
           {:ok, url} <- secure_url(Map.get(entry, "url"), source_where),
           {:ok, commit} <- immutable_commit(Map.get(entry, "commit"), source_where) do
        source = %GitSource{url: url, commit: commit}

        if Enum.any?(acc, &(&1.url == url and &1.commit == commit)) do
          {:halt, {:error, "#{source_where}: duplicate Git URL and commit"}}
        else
          {:cont, {:ok, [source | acc]}}
        end
      else
        false -> {:halt, {:error, "#{source_where} must be a table"}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> reverse_result()
  end

  defp git_sources(other, where),
    do: {:error, "#{where}.git must be an array of tables, got #{type_name(other)}"}

  defp direct_sources(nil, _where), do: {:ok, []}

  defp direct_sources(raw, where) when is_list(raw) do
    raw
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      source_where = "#{where}.direct_urls[#{index}]"

      with true <- is_map(entry),
           entry <- stringify_keys(entry),
           :ok <- reject_unknown_keys(entry, ~w(url sha256), source_where),
           {:ok, url} <- secure_url(Map.get(entry, "url"), source_where),
           {:ok, sha256} <- sha256(Map.get(entry, "sha256"), source_where) do
        source = %DirectSource{url: url, sha256: sha256}

        if Enum.any?(acc, &(&1.url == url)) do
          {:halt, {:error, "#{source_where}: duplicate direct URL"}}
        else
          {:cont, {:ok, [source | acc]}}
        end
      else
        false -> {:halt, {:error, "#{source_where} must be a table"}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> reverse_result()
  end

  defp direct_sources(other, where),
    do: {:error, "#{where}.direct_urls must be an array of tables, got #{type_name(other)}"}

  defp local_roots(nil, _where), do: {:ok, []}

  defp local_roots(raw, where) when is_list(raw) do
    if Enum.all?(raw, &is_binary/1) do
      roots = Enum.map(raw, &expand_path/1)
      absolute? = Enum.map(raw, &(String.starts_with?(&1, "/") or String.starts_with?(&1, "~/")))

      cond do
        not Enum.all?(absolute?) ->
          {:error, "#{where}.local_roots must contain absolute paths"}

        Enum.any?(roots, &(&1 == "/")) ->
          {:error, "#{where}.local_roots must not contain filesystem root /"}

        length(roots) != length(Enum.uniq(roots)) ->
          {:error, "#{where}.local_roots must not contain duplicates"}

        true ->
          {:ok, roots}
      end
    else
      {:error, "#{where}.local_roots must be an array of strings"}
    end
  end

  defp local_roots(other, where),
    do: {:error, "#{where}.local_roots must be an array of strings, got #{type_name(other)}"}

  defp mode_conflicts(:off, packages, where) when packages != %{},
    do: {:error, "#{where}: mode off conflicts with non-empty supply-chain rules"}

  defp mode_conflicts(_, _, _), do: :ok

  defp secure_url(value, where) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    cond do
      uri.scheme != "https" ->
        {:error, "#{where}.url must use https"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "#{where}.url is malformed"}

      uri.userinfo not in [nil, ""] or String.contains?(uri.authority || "", "@") ->
        {:error, "#{where}.url must not contain credentials"}

      uri.query not in [nil, ""] ->
        {:error, "#{where}.url must not contain a query"}

      uri.fragment not in [nil, ""] ->
        {:error, "#{where}.url must not contain a fragment"}

      String.contains?(value, ["[", "]"]) or
          String.contains?(uri.host, [" ", "\n", "\r", "\t"]) ->
        {:error, "#{where}.url is malformed"}

      true ->
        {:ok, String.trim_trailing(value, "/")}
    end
  end

  defp secure_url(_, where), do: {:error, "#{where}.url must be a non-empty https URL"}

  defp optional_secure_url(nil, _where), do: {:ok, nil}

  defp optional_secure_url(value, where) do
    case secure_url(value, where) do
      {:ok, url} -> {:ok, url}
      {:error, message} -> {:error, String.replace(message, ".url", ".download_url")}
    end
  end

  defp credential_env(nil, _where), do: {:ok, nil}

  defp credential_env(value, where) when is_binary(value) do
    if Regex.match?(@env_name, value),
      do: {:ok, value},
      else: {:error, "#{where}.credential_env must be an environment variable name"}
  end

  defp credential_env(_, where), do: {:error, "#{where}.credential_env must be a string"}

  defp immutable_commit(value, where) when is_binary(value) do
    if Regex.match?(@commit, value),
      do: {:ok, String.downcase(value)},
      else: {:error, "#{where}.commit must be a full 40-character immutable commit SHA"}
  end

  defp immutable_commit(_, where),
    do: {:error, "#{where}.commit must be a full 40-character immutable commit SHA"}

  defp sha256(value, where) when is_binary(value) do
    if Regex.match?(@sha256, value),
      do: {:ok, String.downcase(value)},
      else: {:error, "#{where}.sha256 must be a 64-character SHA-256 digest"}
  end

  defp sha256(_, where), do: {:error, "#{where}.sha256 must be a 64-character SHA-256 digest"}

  defp registry_name(policy, ecosystem, pattern),
    do: get_in(policy.package_registries, [ecosystem, pattern])

  defp package_name_allowed?(name, pattern) when is_binary(name) and is_binary(pattern) do
    if String.ends_with?(pattern, "*") do
      String.starts_with?(name, String.trim_trailing(pattern, "*"))
    else
      name == pattern
    end
  end

  defp package_name_allowed?(_, _), do: false

  defp registry_url_matches?(base, source) when is_binary(base) and is_binary(source) do
    base_uri = URI.parse(String.trim_trailing(base, "/"))
    source_uri = URI.parse(source)
    base_path = String.trim_trailing(base_uri.path || "", "/")
    source_path = source_uri.path || ""

    source_uri.scheme == "https" and source_uri.host == base_uri.host and
      source_uri.port == base_uri.port and
      (base_path == "" or source_path == base_path or
         String.starts_with?(source_path, base_path <> "/"))
  end

  defp registry_url_matches?(_, _), do: false

  defp reject_unknown_keys(map, allowed, where) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "#{where}: unknown fields #{inspect(Enum.sort(unknown))}"}
    end
  end

  defp validate_names(names, allowed, label, where) do
    case names -- allowed do
      [] -> :ok
      unknown -> {:error, "#{where}: unknown #{label}(s) #{inspect(Enum.sort(unknown))}"}
    end
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error

  defp local_contained?(path, root) do
    with {:ok, real_path} <- Paths.real(path), {:ok, real_root} <- Paths.real(root) do
      relative = Path.relative_to(real_path, real_root)

      relative == "." or
        (Path.type(relative) == :relative and relative != ".." and
           not String.starts_with?(relative, "../"))
    else
      _ -> false
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp expand_path("~/" <> rest), do: Path.expand(Path.join(System.user_home!(), rest))
  defp expand_path(path) when is_binary(path), do: Path.expand(path)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_map(value), do: "table"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(_), do: "value"
end

defmodule Omashiki.SupplyChain.Error do
  defexception [:message]

  @impl true
  def exception(message) when is_binary(message), do: %__MODULE__{message: message}
end
