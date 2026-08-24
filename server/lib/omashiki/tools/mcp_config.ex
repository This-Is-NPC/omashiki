defmodule Omashiki.Tools.McpConfig do
  @moduledoc "Renders job environment MCP declarations through the internal proxy."

  alias Omashiki.Tools.Proxy

  @default_shape %{"root_key" => "mcp", "server_type" => "remote", "include_enabled" => true}

  @doc "Render only the internal, environment-declared MCP servers."
  def render(environment, profile, ctx) when is_map(environment) and is_map(ctx) do
    render_with_shape(environment, mcp_config_of(profile), ctx)
  end

  def encode(environment, profile, ctx),
    do: environment |> render(profile, ctx) |> Jason.encode!()

  defp mcp_config_of(%{capabilities: caps}) when is_map(caps) do
    case Map.get(caps, "mcp_config") || Map.get(caps, :mcp_config) do
      %{} = shape -> Map.merge(@default_shape, stringify(shape))
      _ -> @default_shape
    end
  end

  defp mcp_config_of(_), do: @default_shape

  defp render_with_shape(environment, shape, ctx) do
    servers = Map.get(environment, "mcp_servers", Map.get(environment, :mcp_servers, %{}))

    servers =
      if is_map(servers) do
        servers
        |> Map.new(fn {name, _declaration} ->
          entry = %{
            "type" => shape["server_type"],
            "url" => proxy_url(name, ctx),
            "headers" => %{"Authorization" => "Bearer #{token(ctx)}"}
          }

          entry = if shape["include_enabled"], do: Map.put(entry, "enabled", true), else: entry
          {name, entry}
        end)
      else
        %{}
      end

    %{shape["root_key"] => servers}
  end

  defp proxy_url(server_name, ctx) do
    base = Map.get(ctx, :base_url) || Map.get(ctx, "base_url") || Proxy.base_url()
    String.trim_trailing(base, "/") <> "/api/v1/tools-proxy/" <> URI.encode(server_name)
  end

  defp token(ctx) do
    case Map.get(ctx, :token) || Map.get(ctx, "token") do
      token when is_binary(token) -> token
      _ -> raise ArgumentError, "runtime MCP context requires a signed token"
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
