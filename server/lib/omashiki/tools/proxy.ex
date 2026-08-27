defmodule Omashiki.Tools.Proxy do
  @moduledoc "Job-scoped internal MCP proxy with capability filtering."

  require Logger

  alias Omashiki.Runtime.Claims
  alias Omashiki.Security.Network

  @doc "Mint a short-lived token for the internal tool data plane."
  def sign_token(job_id, token_owner, admitted_environment_digest)
      when is_binary(job_id) and is_binary(token_owner) and is_binary(admitted_environment_digest) do
    with %Omashiki.Jobs.Job{} = job <- Omashiki.Repo.get(Omashiki.Jobs.Job, job_id),
         {:ok, token} <-
           Claims.issue("tools", job, %{
             token_owner: token_owner,
             admitted_environment_digest: admitted_environment_digest
           }) do
      token
    else
      _ -> nil
    end
  end

  def verify_token(token), do: Claims.verify("tools", token)

  def base_url do
    Application.get_env(:omashiki, :tools_proxy_base_url) ||
      System.get_env("OMASHIKI_TOOLS_PROXY_BASE_URL") ||
      default_base_url()
  end

  @doc "Allow an exact capability or a trailing-star prefix."
  def allowed?(caps, tool_name) when is_list(caps) and is_binary(tool_name) do
    Enum.any?(caps, &match_capability?(&1, tool_name))
  end

  def allowed?(_, _), do: false

  @doc false
  def authorize_upstream(url) when is_binary(url), do: url |> URI.parse() |> validate_upstream()
  def authorize_upstream(_), do: {:error, :invalid_upstream}

  @doc "Handle one internal MCP JSON-RPC request."
  def handle_rpc(server_name, rpc, claims) when is_binary(server_name) and is_map(rpc) do
    with {:ok, %{job: job}} <- Claims.authorize("tools", claims),
         servers when is_map(servers) <- Claims.mcp_servers(job),
         upstream when is_map(upstream) <- Map.get(servers, server_name) || :unknown_server do
      dispatch_rpc(rpc, job, Claims.capabilities(job), server_name, upstream)
    else
      :unknown_server -> {:error, %{code: -32004, message: "unknown_mcp_server"}}
      {:error, :job_missing} -> {:error, %{code: -32001, message: "job_missing"}}
      {:error, :job_not_active} -> {:error, %{code: -32001, message: "job_not_active"}}
      {:error, reason} -> {:error, %{code: -32003, message: Atom.to_string(reason)}}
    end
  end

  def handle_rpc(_, _, _), do: {:error, %{code: -32003, message: "invalid_runtime_scope"}}

  defp dispatch_rpc(%{"method" => "tools/call"} = rpc, job, caps, server, upstream) do
    tool = get_in(rpc, ["params", "name"]) || get_in(rpc, [:params, :name]) || ""
    record(job.id, "tool.requested", server, tool, rpc)

    if allowed?(caps, tool) do
      forward(upstream, rpc)
    else
      record(job.id, "tool.denied", server, tool, rpc)
      {:error, %{code: -32010, message: "tool_denied", data: %{tool: tool, server: server}}}
    end
  end

  defp dispatch_rpc(%{"method" => "tools/list"} = rpc, job, caps, server, upstream) do
    record(job.id, "tool.requested", server, "_list", rpc)

    case forward(upstream, rpc) do
      {:ok, %{"result" => result} = response} when is_map(result) ->
        tools = Map.get(result, "tools") || Map.get(result, :tools) || []
        {:ok, put_in(response, ["result", "tools"], Enum.filter(tools, &tool_allowed?(caps, &1)))}

      other ->
        other
    end
  end

  defp dispatch_rpc(rpc, _job, _caps, _server, upstream), do: forward(upstream, rpc)

  defp tool_allowed?(caps, %{"name" => name}) when is_binary(name), do: allowed?(caps, name)
  defp tool_allowed?(caps, %{name: name}) when is_binary(name), do: allowed?(caps, name)
  defp tool_allowed?(_, _), do: false

  defp match_capability?("*", _), do: true

  defp match_capability?(cap, tool) when is_binary(cap) do
    if String.ends_with?(cap, "*"),
      do: String.starts_with?(tool, String.trim_trailing(cap, "*")),
      else: cap == tool
  end

  defp match_capability?(_, _), do: false

  defp record(job_id, activity, server, tool, rpc) do
    Logger.debug("runtime tool #{activity}",
      job_id: job_id,
      server: server,
      tool: tool,
      method: Map.get(rpc, "method")
    )

    :ok
  end

  defp forward(%{"url" => url} = upstream, rpc) when is_binary(url) do
    headers =
      (Map.get(upstream, "headers", %{}) || %{})
      |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)

    body = Jason.encode!(rpc)
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    host = uri.host || "localhost"
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = if uri.query, do: (uri.path || "/") <> "?" <> uri.query, else: uri.path || "/"

    mint_headers = [
      {"content-type", "application/json"}
      | Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
    ]

    with :ok <- validate_upstream(uri),
         :ok <- Network.authorize_host(uri.host),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, host, port,
             mode: :passive,
             transport_opts: [timeout: 10_000]
           ),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", path, mint_headers, body) do
      receive_http(conn, ref, "", nil)
    end
  rescue
    error -> {:error, %{code: -32020, message: "upstream_unreachable", detail: inspect(error)}}
  end

  defp forward(_, _), do: {:error, %{code: -32004, message: "upstream_missing_url"}}

  defp validate_upstream(%URI{} = uri) do
    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :unsupported_upstream_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :upstream_missing_host}

      uri.userinfo ->
        {:error, :upstream_userinfo_not_allowed}

      uri.fragment ->
        {:error, :upstream_fragment_not_allowed}

      true ->
        Network.authorize_host(uri.host)
    end
  end

  defp receive_http(conn, ref, body, status) do
    case Mint.HTTP.recv(conn, 0, 30_000) do
      {:ok, conn, responses} ->
        {body, status, done?} =
          Enum.reduce(responses, {body, status, false}, fn
            {:status, ^ref, value}, {b, _, d} -> {b, value, d}
            {:data, ^ref, chunk}, {b, s, d} -> {b <> chunk, s, d}
            {:done, ^ref}, {b, s, _} -> {b, s, true}
            _, acc -> acc
          end)

        if done? do
          Mint.HTTP.close(conn)

          if status in 200..299 do
            case Jason.decode(body) do
              {:ok, decoded} -> {:ok, decoded}
              _ -> {:error, %{code: -32700, message: "upstream_invalid_json"}}
            end
          else
            {:error, %{code: -32020, message: "upstream_http_#{status}"}}
          end
        else
          receive_http(conn, ref, body, status)
        end

      {:error, conn, reason, _} ->
        Mint.HTTP.close(conn)
        {:error, %{code: -32020, message: "upstream_unreachable", detail: inspect(reason)}}
    end
  end

  defp default_base_url do
    port =
      case Application.get_env(:omashiki, OmashikiWeb.Endpoint) do
        opts when is_list(opts) -> Keyword.get(Keyword.get(opts, :http, []), :port, 4000)
        _ -> 4000
      end

    "http://host.docker.internal:#{port}"
  end
end
