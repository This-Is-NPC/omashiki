defmodule Omashiki.SupplyChain.Dependency do
  @moduledoc "One dependency discovered in a project manifest or lockfile."

  defstruct ecosystem: nil,
            name: nil,
            version: nil,
            constraint: nil,
            source: :unknown,
            source_url: nil,
            commit: nil,
            sha256: nil,
            path: nil,
            file: nil,
            locked: false
end

defmodule Omashiki.SupplyChain.Manifest do
  @moduledoc """
  Small, dependency-free inspectors for the supported package manifests.

  This module intentionally does not resolve dependencies. Lockfiles are
  inspected when present, while manifest constraints remain visible as
  `constraint` so preflight can fail closed when no immutable version exists.
  """

  alias Omashiki.SupplyChain.{Dependency, Paths}

  import Kernel, except: [inspect: 1]

  defstruct root: nil, files: [], dependencies: []

  @supported ~w(package.json package-lock.json Cargo.toml Cargo.lock go.mod go.sum)

  @doc "Inspect supported manifests below `root`."
  def inspect(root) when is_binary(root) do
    with {:ok, root} <- real_directory(root),
         {:ok, package} <- inspect_package(root),
         {:ok, cargo} <- inspect_cargo(root),
         {:ok, go} <- inspect_go(root) do
      dependencies = package ++ cargo ++ go
      files = Enum.filter(@supported, &regular?(Path.join(root, &1)))
      {:ok, %__MODULE__{root: root, files: files, dependencies: dependencies}}
    end
  end

  def inspect(_), do: {:error, "preflight root must be a directory"}

  defp inspect_package(root) do
    package_path = Path.join(root, "package.json")
    lock_path = Path.join(root, "package-lock.json")

    with {:ok, package} <- decode_json(package_path),
         {:ok, lock} <- decode_json(lock_path) do
      manifest =
        package
        |> package_dependencies()
        |> Enum.map(fn {name, requirement} ->
          dependency("npm", name, requirement, root, package_path, false)
        end)

      locked = package_lock_dependencies(lock, root, lock_path)
      {:ok, merge_locked(manifest, locked)}
    end
  end

  defp inspect_cargo(root) do
    toml_path = Path.join(root, "Cargo.toml")
    lock_path = Path.join(root, "Cargo.lock")

    with {:ok, toml} <- decode_toml(toml_path),
         {:ok, lock} <- decode_toml(lock_path) do
      manifest =
        ["dependencies", "dev-dependencies", "build-dependencies"]
        |> Enum.flat_map(fn section ->
          toml
          |> Map.get(section, %{})
          |> map_entries()
          |> Enum.map(fn {name, requirement} ->
            cargo_dependency(name, requirement, root, toml_path)
          end)
        end)

      {:ok, manifest ++ cargo_lock_dependencies(lock, lock_path)}
    end
  end

  defp inspect_go(root) do
    mod_path = Path.join(root, "go.mod")
    sum_path = Path.join(root, "go.sum")

    with {:ok, mod} <- read_optional(mod_path),
         {:ok, sum} <- read_optional(sum_path) do
      {:ok, go_mod_dependencies(mod, root, mod_path) ++ go_sum_dependencies(sum, sum_path)}
    end
  end

  defp decode_json(path) do
    if regular?(path) do
      case File.read(path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, map} when is_map(map) -> {:ok, map}
            {:ok, _} -> {:error, "#{path} must contain a JSON object"}
            {:error, reason} -> {:error, "#{path} is invalid JSON: #{Exception.message(reason)}"}
          end

        {:error, reason} ->
          {:error, "cannot read #{path}: #{Kernel.inspect(reason)}"}
      end
    else
      {:ok, %{}}
    end
  end

  defp decode_toml(path) do
    if regular?(path) do
      case Toml.decode_file(path) do
        {:ok, map} when is_map(map) -> {:ok, stringify_keys(map)}
        {:error, reason} -> {:error, "#{path} is invalid TOML: #{Kernel.inspect(reason)}"}
      end
    else
      {:ok, %{}}
    end
  end

  defp read_optional(path) do
    if regular?(path), do: File.read(path), else: {:ok, ""}
  end

  defp real_directory(root) do
    with {:ok, root} <- Paths.real(root),
         true <- File.dir?(root) do
      {:ok, root}
    else
      _ -> {:error, "preflight root must be a real directory"}
    end
  end

  defp package_dependencies(package) do
    ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]
    |> Enum.flat_map(fn section -> package |> Map.get(section, %{}) |> map_entries() end)
  end

  defp package_lock_dependencies(%{"packages" => packages}, root, path) when is_map(packages) do
    packages
    |> Enum.reject(fn {name, _} -> name == "" end)
    |> Enum.flat_map(fn {package_path, attrs} ->
      locked_npm_dependency(package_name(package_path), attrs, root, path)
    end)
  end

  defp package_lock_dependencies(%{"dependencies" => dependencies}, root, path)
       when is_map(dependencies),
       do: flatten_npm_dependencies(dependencies, root, path)

  defp package_lock_dependencies(_, _, _), do: []

  defp flatten_npm_dependencies(dependencies, root, path) do
    Enum.flat_map(dependencies, fn {name, attrs} ->
      attrs = stringify_keys(attrs)
      current = locked_npm_dependency(name, attrs, root, path)
      nested = attrs |> Map.get("dependencies", %{}) |> flatten_npm_dependencies(root, path)
      current ++ nested
    end)
  end

  defp locked_npm_dependency(name, attrs, root, path) do
    attrs = stringify_keys(attrs)
    version = Map.get(attrs, "version")
    resolved = Map.get(attrs, "resolved")
    integrity = Map.get(attrs, "integrity")
    {source, source_url} = npm_lock_source(resolved)

    if is_binary(name) and is_binary(version) do
      [
        %Dependency{
          ecosystem: "npm",
          name: name,
          version: version,
          source: source,
          source_url: source_url,
          commit: source_commit(resolved),
          sha256: integrity_sha256(integrity),
          path: local_path(resolved, root),
          file: path,
          locked: true
        }
      ]
    else
      []
    end
  end

  defp npm_lock_source(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "https" and uri.host == "registry.npmjs.org" do
      {:registry, "https://registry.npmjs.org"}
    else
      {classify_url(value), source_url(value)}
    end
  end

  defp npm_lock_source(_), do: {:registry, nil}

  defp merge_locked(manifest, locked) do
    locked_by_name = Map.new(locked, &{&1.name, &1})
    manifest_names = MapSet.new(manifest, & &1.name)

    manifest =
      Enum.map(manifest, fn dependency ->
        case Map.get(locked_by_name, dependency.name) do
          nil -> dependency
          locked_dependency -> %{locked_dependency | constraint: dependency.constraint}
        end
      end)

    Enum.concat(manifest, Enum.reject(locked, &MapSet.member?(manifest_names, &1.name)))
  end

  defp cargo_dependency(name, requirement, root, path) do
    attrs =
      if is_map(requirement), do: stringify_keys(requirement), else: %{"version" => requirement}

    version = Map.get(attrs, "version")
    git = Map.get(attrs, "git")
    rev = Map.get(attrs, "rev")
    local = Map.get(attrs, "path")

    cond do
      is_binary(local) ->
        %Dependency{
          ecosystem: "cargo",
          name: name,
          version: version,
          constraint: version,
          source: :local,
          path: Path.expand(local, root),
          file: path
        }

      is_binary(git) ->
        %Dependency{
          ecosystem: "cargo",
          name: name,
          version: version,
          constraint: version,
          source: :git,
          source_url: strip_git_scheme(git),
          commit: rev,
          file: path
        }

      true ->
        %Dependency{
          ecosystem: "cargo",
          name: name,
          version: version,
          constraint: version,
          source: :registry,
          file: path
        }
    end
  end

  defp cargo_lock_dependencies(%{"package" => packages}, path) when is_list(packages) do
    Enum.flat_map(packages, fn attrs ->
      attrs = stringify_keys(attrs)
      name = Map.get(attrs, "name")
      version = Map.get(attrs, "version")
      source = Map.get(attrs, "source")

      if is_binary(name) and is_binary(version) do
        [
          %Dependency{
            ecosystem: "cargo",
            name: name,
            version: version,
            source: classify_cargo_source(source),
            source_url: cargo_source_url(source),
            commit: cargo_source_commit(source),
            file: path,
            locked: true
          }
        ]
      else
        []
      end
    end)
  end

  defp cargo_lock_dependencies(_, _), do: []

  defp go_mod_dependencies(contents, root, path) do
    replacements = go_replacements(contents, root)

    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      trimmed = String.trim_leading(String.trim(line), "require ")

      case Regex.run(~r/^([[:alnum:]_.~\/-]+)\s+(v[^\s]+)(?:\s+\/\/.*)?$/, trimmed) do
        [_, name, version] ->
          case Map.get(replacements, name) do
            nil ->
              [
                %Dependency{
                  ecosystem: "go",
                  name: name,
                  version: version,
                  source: :registry,
                  file: "#{path}:#{line_number}"
                }
              ]

            local_path ->
              [
                %Dependency{
                  ecosystem: "go",
                  name: name,
                  version: version,
                  source: :local,
                  path: local_path,
                  file: "#{path}:#{line_number}"
                }
              ]
          end

        _ ->
          []
      end
    end)
  end

  defp go_replacements(contents, root) do
    contents
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*replace\s+([^\s]+)(?:\s+v[^\s]+)?\s+=>\s+([^\s]+)\s*$/, line) do
        [_, name, local] ->
          if String.starts_with?(local, "http") do
            []
          else
            [{name, Path.expand(local, root)}]
          end

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp go_sum_dependencies(contents, path) do
    contents
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), " ") do
        [name, version, _hash] ->
          if String.ends_with?(version, "/go.mod") do
            []
          else
            [
              %Dependency{
                ecosystem: "go",
                name: name,
                version: version,
                source: :registry,
                file: path,
                locked: true
              }
            ]
          end

        _ ->
          []
      end
    end)
  end

  defp dependency(ecosystem, name, requirement, root, path, locked) do
    requirement = if is_binary(requirement), do: requirement, else: nil

    %Dependency{
      ecosystem: ecosystem,
      name: name,
      version: requirement,
      constraint: requirement,
      source: classify_url(requirement),
      source_url: source_url(requirement),
      commit: source_commit(requirement),
      path: local_path(requirement, root),
      file: path,
      locked: locked
    }
  end

  defp classify_url(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "file:") -> :local
      String.starts_with?(value, "git+") -> :git
      String.starts_with?(value, "git://") -> :git
      String.starts_with?(value, "https://") and String.contains?(value, ".tar") -> :direct_url
      String.starts_with?(value, "https://") -> :direct_url
      String.starts_with?(value, "http://") -> :direct_url
      true -> :registry
    end
  end

  defp classify_url(_), do: :registry

  defp classify_cargo_source(source) when is_binary(source) do
    cond do
      String.starts_with?(source, "registry+") -> :registry
      String.starts_with?(source, "git+") -> :git
      true -> :unknown
    end
  end

  defp classify_cargo_source(_), do: :registry

  defp source_url(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "git+") ->
        value |> strip_git_scheme() |> drop_fragment()

      String.starts_with?(value, "git://") ->
        drop_fragment(value)

      String.starts_with?(value, "registry+") ->
        value |> String.trim_leading("registry+") |> drop_fragment()

      String.starts_with?(value, "http://") ->
        drop_fragment(value)

      String.starts_with?(value, "https://") ->
        drop_fragment(value)

      true ->
        nil
    end
  end

  defp source_url(_), do: nil

  defp cargo_source_url(source), do: source_url(source)

  defp source_commit(value) when is_binary(value) do
    case String.split(value, "#", parts: 2) do
      [_, commit] when commit != "" -> commit
      _ -> nil
    end
  end

  defp source_commit(_), do: nil

  defp cargo_source_commit(source), do: source_commit(source)

  defp local_path("file:" <> relative, root), do: Path.expand(relative, root)
  defp local_path(_, _), do: nil

  defp integrity_sha256("sha256-" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, digest} when byte_size(digest) == 32 -> Base.encode16(digest, case: :lower)
      _ -> nil
    end
  end

  defp integrity_sha256(_), do: nil

  defp package_name(package_path) do
    package_path
    |> String.split("/node_modules/", parts: 2)
    |> List.last()
    |> case do
      "node_modules/" <> name -> name
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp strip_git_scheme("git+" <> url), do: url
  defp strip_git_scheme(url), do: url

  defp drop_fragment(url), do: url |> String.split("#", parts: 2) |> hd()

  defp map_entries(%{} = map), do: Map.to_list(map)
  defp map_entries(_), do: []

  defp regular?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _ -> false
    end
  end

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
