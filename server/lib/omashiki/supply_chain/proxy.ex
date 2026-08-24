defmodule Omashiki.SupplyChain.Proxy do
  require Logger

  @moduledoc """
  Policy-bound package proxy for npm, Cargo sparse/download, and Go proxy.

  The proxy never accepts an upstream URL from a request. It derives the target
  from the signed job token's cache group and the registry declarations in that
  group's policy. The network client is deliberately injectable so policy and
  controller tests can use Bypass/local HTTPS without weakening production URL
  validation.
  """

  alias Omashiki.Config
  alias Omashiki.Runtime.Claims
  alias Omashiki.SupplyChain.{Policy, Registry}

  @default_timeout_ms 15_000
  @default_max_bytes 64 * 1024 * 1024
  @redirect_statuses 300..399

  @doc "Sign a token scoped to one job, owner, environment, cache, and policy."
  def sign_token(job_id, token_owner, environment_digest, cache_group, policy_digest)
      when is_binary(job_id) and is_binary(token_owner) and is_binary(environment_digest) and
             is_binary(cache_group) and is_binary(policy_digest) do
    with %Omashiki.Jobs.Job{} = job <- Omashiki.Repo.get(Omashiki.Jobs.Job, job_id),
         {:ok, token} <-
           Claims.issue("supply_chain", job, %{
             token_owner: token_owner,
             environment_digest: environment_digest,
             cache_group: cache_group,
             policy_digest: policy_digest
           }) do
      token
    else
      _ -> nil
    end
  end

  def verify_token(token), do: Claims.verify("supply_chain", token)

  @doc "Base URL reachable by an agent container for the package proxy."
  def base_url do
    Application.get_env(:omashiki, :supply_chain_proxy_base_url) ||
      System.get_env("OMASHIKI_SUPPLY_CHAIN_PROXY_BASE_URL") ||
      default_base_url()
  end

  @doc "Build a package-manager URL carrying a job-bound proxy token."
  def url(cache_group, ecosystem, token, opts \\ []) do
    base = Keyword.get(opts, :base_url, base_url())

    String.trim_trailing(base, "/") <>
      "/api/v1/supply-chain/" <>
      URI.encode(cache_group) <>
      "/" <> ecosystem <> "/" <> URI.encode(token, &URI.char_unreserved?/1) <> "/"
  end

  @doc "Handle one package-manager request."
  def handle_request(method, request_path, headers, claims, opts \\ [])

  def handle_request(method, request_path, headers, claims, opts)
      when method in ["GET", "HEAD"] and is_binary(request_path) and is_map(claims) do
    opts =
      Keyword.put_new(
        opts,
        :emit_events,
        Application.get_env(:omashiki, :supply_chain_emit_events, true)
      )

    with {:ok, context} <- policy_context(claims),
         {:ok, request} <- parse_request(request_path),
         {:ok, ecosystem, relative_path} <- ecosystem_path(request.path),
         {:ok, package, version} <- request_subject(ecosystem, relative_path, request.query),
         {:ok, registry} <- choose_registry(context.policy, ecosystem, request.query, package),
         decision <- decision(context.policy, ecosystem, package, version),
         :ok <- record_decision(context, ecosystem, registry, package, version, decision, opts),
         :ok <- deny_if_blocked(decision),
         {:ok, response} <- fetch(registry, relative_path, method, headers, opts),
         :ok <- enforce_response_size(response, opts),
         context = Map.put(context, :package, package),
         {:ok, response} <-
           filter_response(ecosystem, relative_path, response, decision, context, opts) do
      {:ok, response}
    else
      {:error, :blocked, reason} -> {:error, %{status: 403, message: reason}}
      {:error, reason} -> {:error, %{status: 400, message: format_reason(reason)}}
    end
  end

  def handle_request(_, _, _, _, _), do: {:error, %{status: 405, message: "method_not_allowed"}}

  @doc false
  def handle(method, request_path, headers, claims, opts \\ []),
    do: handle_request(method, request_path, headers, claims, opts)

  defp policy_context(claims) do
    cache_group = claims["cache_group"] || claims[:cache_group]

    with {:ok, %{job: job}} <- Claims.authorize("supply_chain", claims, cache_group: cache_group),
         cache when not is_nil(cache) <- Config.get_cache(cache_group),
         %Policy{} = policy <- cache.policy,
         snapshot when is_map(snapshot) <- Claims.cache_snapshot(job, cache_group),
         digest <- Map.get(snapshot["policy"] || %{}, "digest"),
         true <- digest == claims["policy_digest"] and policy.digest == digest do
      {:ok, %{job_id: job.id, cache_group: cache_group, policy: policy}}
    else
      nil -> {:error, :cache_group_not_found}
      false -> {:error, :policy_changed}
      _ -> {:error, :policy_required}
    end
  end

  defp parse_request(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, :absolute_url_rejected}

      String.contains?(path, ["\\", "\0"]) ->
        {:error, :invalid_path}

      true ->
        uri = URI.parse("http://proxy" <> path)
        decoded_path = URI.decode(uri.path || "/")

        if uri.host == "proxy" and
             not String.contains?(decoded_path, ["..", "//", "\\", "\0"]) do
          {:ok, %{path: decoded_path, query: URI.decode_query(uri.query || "")}}
        else
          {:error, :invalid_path}
        end
    end
  end

  defp ecosystem_path("/npm/" <> path), do: {:ok, "npm", path}
  defp ecosystem_path("/cargo/" <> path), do: {:ok, "cargo", path}
  defp ecosystem_path("/go/" <> path), do: {:ok, "go", path}
  defp ecosystem_path(_), do: {:error, :unknown_ecosystem_path}

  defp choose_registry(policy, ecosystem, query, package) do
    query_registry = Map.get(query, "registry")

    package_registry =
      case Policy.package_rule(policy, ecosystem, package) do
        {_constraint, registry} -> registry
        _ -> nil
      end

    requested = query_registry || package_registry

    case {query_registry, package_registry} do
      {query_registry, package_registry}
      when is_binary(query_registry) and is_binary(package_registry) and
             query_registry != package_registry ->
        {:error, :registry_not_allowlisted_for_package}

      _ ->
        case Policy.select_registry(policy, ecosystem, name: requested) do
          %Registry{} = registry -> {:ok, registry}
          nil -> {:error, :registry_not_declared}
        end
    end
  end

  defp request_subject("npm", path, query) do
    package = npm_package(path)

    version =
      case {String.contains?(path, "/-/"), Map.get(query, "version")} do
        {true, version} when is_binary(version) and version != "" -> version
        {true, _version} -> :unknown_artifact_version
        {false, _version} -> nil
      end

    {:ok, package, version}
  end

  defp request_subject("cargo", path, _query) do
    cond do
      path == "config.json" ->
        {:ok, nil, nil}

      String.ends_with?(path, "/download") ->
        parts = String.split(path, "/", trim: true)
        {:ok, Enum.at(parts, -3), Enum.at(parts, -2)}

      true ->
        {:ok, cargo_package(path), nil}
    end
  end

  defp request_subject("go", path, _query) do
    case Regex.run(~r{^(.+)/@v/([^/]+)\.(?:info|mod|zip)$}, path) do
      [_, package, version] -> {:ok, URI.decode(package), version}
      _ -> {:ok, go_package(path), nil}
    end
  end

  defp decision(%Policy{mode: :off}, _ecosystem, _package, _version), do: :allow
  defp decision(_policy, _ecosystem, nil, _version), do: :allow

  defp decision(policy, _ecosystem, _package, :unknown_artifact_version),
    do: decision_for_mode(policy, :version)

  defp decision(policy, ecosystem, package, version) do
    case Policy.package_rule(policy, ecosystem, package) do
      {_constraint, _registry} when is_nil(version) ->
        :allow

      {constraint, _registry} when is_binary(version) ->
        if Policy.version_allowed?(version, constraint),
          do: :allow,
          else: decision_for_mode(policy, :version)

      _ ->
        decision_for_mode(policy, :package)
    end
  end

  defp decision_for_mode(%Policy{mode: :audit}, reason), do: {:audit, reason}
  defp decision_for_mode(%Policy{mode: :allowlist}, reason), do: {:blocked, reason}

  defp deny_if_blocked({:blocked, reason}), do: {:error, :blocked, blocked_message(reason)}
  defp deny_if_blocked(_), do: :ok

  defp blocked_message(:version), do: "package version is not allowlisted"
  defp blocked_message(:package), do: "package is not allowlisted"

  defp record_decision(context, ecosystem, registry, package, version, decision, opts) do
    if Keyword.get(opts, :emit_events, true) do
      {activity, outcome} =
        case decision do
          {:blocked, _} -> {"registry.blocked", "denied"}
          {:audit, _} -> {"registry.blocked", "ok"}
          :allow -> {"registry.allowed", "ok"}
        end

      Logger.debug("supply-chain registry decision",
        job_id: context.job_id,
        activity: activity,
        outcome: outcome,
        ecosystem: ecosystem,
        registry: registry.name,
        package: package,
        version: version,
        mode: context.policy.mode
      )
    end

    :ok
  end

  defp fetch(%Registry{} = registry, path, method, request_headers, opts) do
    url = upstream_url(registry, path)
    headers = upstream_headers(request_headers, registry)

    case Keyword.get(opts, :fetcher) || Application.get_env(:omashiki, :supply_chain_fetcher) do
      fun when is_function(fun, 3) ->
        normalize_fetch_result(fun.(method, url, headers))

      _ ->
        mint_fetch(method, url, headers, opts)
    end
  end

  defp normalize_fetch_result({:ok, %{status: status, headers: headers, body: body}}),
    do: {:ok, %{status: status, headers: normalize_headers(headers), body: body}}

  defp normalize_fetch_result({status, headers, body}) when is_integer(status),
    do: {:ok, %{status: status, headers: normalize_headers(headers), body: body}}

  defp normalize_fetch_result({:error, reason}), do: {:error, reason}
  defp normalize_fetch_result(_), do: {:error, :invalid_fetcher_response}

  defp mint_fetch(method, url, headers, opts) do
    uri = URI.parse(url)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    port = uri.port || 443

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, uri.host, port,
             mode: :passive,
             transport_opts: [verify: :verify_peer]
           ),
         {:ok, conn, _ref} <- Mint.HTTP.request(conn, method, uri_path(uri), headers, "") do
      deadline = System.monotonic_time(:millisecond) + timeout
      recv_response(conn, deadline, max_bytes, [])
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_response(conn, deadline, max_bytes, responses) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, received} ->
        responses = responses ++ received

        cond do
          redirect_response?(responses) ->
            Mint.HTTP.close(conn)
            {:error, :redirect_not_allowed}

          response_content_length(responses) > max_bytes or
              response_body_size(responses) > max_bytes ->
            Mint.HTTP.close(conn)
            {:error, :response_too_large}

          Enum.any?(received, &match?({:done, _}, &1)) ->
            Mint.HTTP.close(conn)
            response_from_mint(responses, max_bytes)

          timeout == 0 ->
            Mint.HTTP.close(conn)
            {:error, :timeout}

          true ->
            recv_response(conn, deadline, max_bytes, responses)
        end

      {:error, conn, reason, _received} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp redirect_response?(responses) do
    Enum.any?(responses, fn
      {:status, _ref, status} when status in @redirect_statuses -> true
      _ -> false
    end)
  end

  defp response_content_length(responses) do
    responses
    |> Enum.find_value(0, fn
      {:headers, _ref, headers} ->
        case Enum.find(headers, fn {key, _value} -> String.downcase(key) == "content-length" end) do
          {_key, value} -> parse_content_length(value)
          nil -> 0
        end

      _ ->
        nil
    end)
  end

  defp parse_content_length(value) do
    case Integer.parse(to_string(value)) do
      {length, ""} when length >= 0 -> length
      _ -> 0
    end
  end

  defp response_body_size(responses) do
    Enum.reduce(responses, 0, fn
      {:data, _ref, data}, total -> total + byte_size(data)
      _event, total -> total
    end)
  end

  defp response_from_mint(responses, max_bytes) do
    status =
      Enum.find_value(responses, fn
        {:status, _ref, status} -> status
        _ -> nil
      end)

    headers =
      Enum.find_value(responses, [], fn
        {:headers, _ref, headers} -> headers
        _ -> nil
      end)

    body = for {:data, _ref, data} <- responses, into: "", do: data

    cond do
      is_nil(status) -> {:error, :upstream_missing_status}
      byte_size(body) > max_bytes -> {:error, :response_too_large}
      Enum.any?(responses, &match?({:error, _, _}, &1)) -> {:error, :upstream_error}
      true -> {:ok, %{status: status, headers: normalize_headers(headers), body: body}}
    end
  end

  defp filter_response(
         _ecosystem,
         _path,
         %{status: status},
         _decision,
         _context,
         _opts
       )
       when status in @redirect_statuses,
       do: {:error, :redirect_not_allowed}

  defp filter_response("npm", path, response, decision, context, opts) do
    if metadata_request?(path) and not match?({:blocked, _}, decision) do
      filter_npm_metadata(response, decision, context, opts)
    else
      {:ok, response}
    end
  end

  defp filter_response("cargo", path, response, decision, context, opts) do
    cond do
      path == "config.json" ->
        rewrite_cargo_registry_config(response, context, opts)

      sparse_record?(path) and not match?({:blocked, _}, decision) ->
        filter_cargo_sparse(response, decision, context, opts)

      true ->
        {:ok, response}
    end
  end

  defp filter_response("go", path, response, decision, context, _opts) do
    if String.ends_with?(path, "/@v/list") and not match?({:blocked, _}, decision) do
      {:ok, filter_go_versions(response, decision, context)}
    else
      {:ok, response}
    end
  end

  defp filter_npm_metadata(response, {:audit, _}, _context, _opts), do: {:ok, response}

  defp filter_npm_metadata(response, :allow, context, opts) do
    if context.policy.mode == :audit do
      {:ok, response}
    else
      filter_npm_allowlisted_metadata(response, context, opts)
    end
  end

  defp filter_npm_allowlisted_metadata(response, context, opts) do
    case Jason.decode(response.body) do
      {:ok, %{"versions" => versions} = metadata} when is_map(versions) ->
        versions =
          Enum.filter(versions, fn {version, _} ->
            allowed_version?(context.policy, "npm", context.package, version)
          end)
          |> Map.new()

        metadata = Map.put(metadata, "versions", rewrite_npm_versions(versions, context, opts))
        {:ok, rewrite_response(response, Jason.encode!(metadata), opts, context)}

      _ ->
        {:error, :invalid_npm_metadata}
    end
  end

  defp filter_cargo_sparse(response, {:audit, _}, _context, _opts), do: {:ok, response}

  defp filter_cargo_sparse(response, :allow, context, opts) do
    if context.policy.mode == :audit do
      {:ok, response}
    else
      filter_cargo_allowlisted_sparse(response, context, opts)
    end
  end

  defp filter_cargo_allowlisted_sparse(response, context, opts) do
    records =
      response.body
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"vers" => version} = record} ->
            if allowed_version?(context.policy, "cargo", context.package, version) do
              [Map.put(record, "dl", cargo_download_url(context, opts, version))]
            else
              []
            end

          _ ->
            []
        end
      end)

    {:ok,
     rewrite_response(
       response,
       Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n",
       opts,
       context
     )}
  end

  defp filter_go_versions(response, {:audit, _}, _context), do: response

  defp filter_go_versions(response, :allow, context) do
    if context.policy.mode == :audit do
      response
    else
      filter_go_allowlisted_versions(response, context)
    end
  end

  defp filter_go_allowlisted_versions(response, context) do
    body =
      response.body
      |> String.split("\n", trim: true)
      |> Enum.filter(&allowed_version?(context.policy, "go", context.package, &1))
      |> Enum.join("\n")

    %{
      response
      | body: if(body == "", do: "", else: body <> "\n"),
        headers: drop_length(response.headers)
    }
  end

  defp allowed_version?(policy, ecosystem, package, version) do
    case Policy.package_rule(policy, ecosystem, package) do
      {constraint, _} -> Policy.version_allowed?(version, constraint)
      _ -> false
    end
  end

  defp rewrite_npm_versions(versions, context, opts) do
    Enum.map(versions, fn {version, attrs} ->
      attrs =
        if is_map(attrs) do
          Map.update(attrs, "dist", %{}, fn dist ->
            if is_map(dist) and is_binary(dist["tarball"]) do
              Map.put(dist, "tarball", npm_artifact_url(context, opts, version, dist["tarball"]))
            else
              dist
            end
          end)
        else
          attrs
        end

      {version, attrs}
    end)
    |> Map.new()
  end

  defp npm_artifact_url(context, opts, version, upstream_url) do
    filename = upstream_url |> URI.parse() |> Map.get(:path, "") |> Path.basename()
    filename = if filename in ["", "."], do: "#{context.package}-#{version}.tgz", else: filename
    token = Keyword.get(opts, :token, "")
    token_path = if token == "", do: "", else: URI.encode(token, &URI.char_unreserved?/1) <> "/"

    String.trim_trailing(Keyword.get(opts, :base_url, base_url()), "/") <>
      "/api/v1/supply-chain/" <>
      URI.encode(context.cache_group) <>
      "/npm/" <>
      token_path <>
      URI.encode(context.package, &URI.char_unreserved?/1) <>
      "/-/" <> URI.encode(filename) <> "?version=" <> URI.encode_www_form(version)
  end

  defp rewrite_response(response, body, _opts, _context),
    do: %{response | body: body, headers: drop_length(response.headers)}

  defp cargo_download_url(context, opts, version) do
    token = Keyword.get(opts, :token, "")
    base = String.trim_trailing(Keyword.get(opts, :base_url, base_url()), "/")
    token_path = if token == "", do: "", else: URI.encode(token, &URI.char_unreserved?/1) <> "/"

    base <>
      "/api/v1/supply-chain/" <>
      URI.encode(context.cache_group) <>
      "/cargo/" <>
      token_path <>
      "api/v1/crates/" <>
      URI.encode(context.package) <>
      "/" <>
      URI.encode(version) <>
      "/download"
  end

  defp rewrite_cargo_registry_config(response, context, opts) do
    case Jason.decode(response.body) do
      {:ok, config} when is_map(config) ->
        token = Keyword.get(opts, :token, "")

        token_path =
          if token == "", do: "", else: URI.encode(token, &URI.char_unreserved?/1) <> "/"

        download =
          String.trim_trailing(Keyword.get(opts, :base_url, base_url()), "/") <>
            "/api/v1/supply-chain/" <>
            URI.encode(context.cache_group) <>
            "/cargo/" <> token_path <> "api/v1/crates/{crate}/{version}/download"

        {:ok,
         rewrite_response(response, Jason.encode!(Map.put(config, "dl", download)), opts, context)}

      _ ->
        {:error, :invalid_cargo_config}
    end
  end

  defp enforce_response_size(%{body: body}, opts) when is_binary(body) do
    if byte_size(body) <= Keyword.get(opts, :max_bytes, @default_max_bytes),
      do: :ok,
      else: {:error, :response_too_large}
  end

  defp enforce_response_size(_, _), do: {:error, :invalid_upstream_response}

  defp upstream_headers(request_headers, %Registry{credential_env: env}) do
    headers =
      request_headers
      |> normalize_headers()
      |> Enum.filter(fn {key, _} ->
        String.downcase(key) in [
          "accept",
          "content-type",
          "if-none-match",
          "if-modified-since",
          "user-agent"
        ]
      end)

    case env && System.get_env(env) do
      value when is_binary(value) and value != "" ->
        [{"authorization", "Bearer " <> value} | headers]

      _ ->
        headers
    end
  end

  defp join_url(base, path),
    do: String.trim_trailing(base, "/") <> "/" <> String.trim_leading(path, "/")

  defp upstream_url(%Registry{url: registry_url, download_url: template}, path)
       when is_binary(template) and template != "" do
    case Regex.run(~r{(?:^|/)api/v1/crates/([^/]+)/([^/]+)/download$}, path) do
      [_, package, version] ->
        if String.contains?(template, ["{crate}", "{version}"]) do
          template
          |> String.replace("{crate}", URI.encode(package))
          |> String.replace("{version}", URI.encode(version))
        else
          join_url(template, path)
        end

      _ ->
        join_url(registry_url, path)
    end
  end

  defp upstream_url(%Registry{url: url}, path), do: join_url(url, path)

  defp uri_path(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if uri.query, do: path <> "?" <> uri.query, else: path
  end

  defp normalize_headers(headers) when is_map(headers),
    do: Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp normalize_headers(headers) when is_list(headers),
    do: Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp normalize_headers(_), do: []

  defp metadata_request?(path), do: not String.contains?(path, "/-/")

  defp sparse_record?(path),
    do: path != "config.json" and not String.contains?(path, "api/v1/crates")

  defp npm_package(path) do
    path = URI.decode(path)

    if String.starts_with?(path, "@"),
      do: path |> String.split("/-/", parts: 2) |> hd(),
      else: path |> String.split("/-/", parts: 2) |> hd()
  end

  defp cargo_package(path), do: path |> String.split("/", trim: true) |> List.last()

  defp go_package(path) do
    path
    |> String.split("/@v/", parts: 2)
    |> hd()
    |> URI.decode()
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp drop_length(headers),
    do:
      Enum.reject(headers, fn {key, _} ->
        String.downcase(key) in ["content-length", "transfer-encoding"]
      end)

  defp default_base_url do
    port = Application.get_env(:omashiki, OmashikiWeb.Endpoint) |> endpoint_port()

    host =
      if Application.get_env(:omashiki, :agent_network_mode) == "host",
        do: "127.0.0.1",
        else: "host.docker.internal"

    "http://#{host}:#{port}"
  end

  defp endpoint_port(opts) when is_list(opts),
    do: Keyword.get(Keyword.get(opts, :http, []), :port, 4000)

  defp endpoint_port(_), do: 4000
end
