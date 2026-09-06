defmodule Omashiki.Identities.Broker do
  @moduledoc """
  The house wearing an identity on the agent's behalf.

  While a job runs, its sandbox reaches the manager through the tools data
  plane (`/api/v1/tools-proxy/<server>`). When `<server>` names an identity
  the admitted preset wears, the request is not forwarded anywhere: this
  module answers it as an in-process MCP server, acting as that identity.

  Binding is by name, captured at admission. The admitted environment carries
  the identity's public view; the private key is read from the live
  `Omashiki.Config` in this process only. A job whose preset wears nothing
  never reaches this module. The environment's `capabilities` allowlist
  applies to these tools exactly as it does to any other MCP server.
  """

  require Logger

  alias Omashiki.Config
  alias Omashiki.Config.Identity
  alias Omashiki.Identities.GithubApp
  alias Omashiki.Jobs.Job

  @tools [
    %{
      "name" => "github_get_issue",
      "description" => "Read an issue or pull request as the agent's GitHub App.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["repository", "number"],
        "properties" => %{
          "repository" => %{"type" => "string", "description" => "owner/name"},
          "number" => %{"type" => "integer"}
        }
      }
    },
    %{
      "name" => "github_comment",
      "description" => "Comment on an issue or pull request as the agent's GitHub App.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["repository", "number", "body"],
        "properties" => %{
          "repository" => %{"type" => "string", "description" => "owner/name"},
          "number" => %{"type" => "integer"},
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "github_add_labels",
      "description" => "Add labels to an issue or pull request as the agent's GitHub App.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["repository", "number", "labels"],
        "properties" => %{
          "repository" => %{"type" => "string", "description" => "owner/name"},
          "number" => %{"type" => "integer"},
          "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    },
    %{
      "name" => "github_create_pull_request",
      "description" => "Open a pull request as the agent's GitHub App.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["repository", "title", "head", "base"],
        "properties" => %{
          "repository" => %{"type" => "string", "description" => "owner/name"},
          "title" => %{"type" => "string"},
          "head" => %{"type" => "string"},
          "base" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "draft" => %{"type" => "boolean"}
        }
      }
    }
  ]

  @repository ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

  @doc "Names of the identities an admitted (or live) environment's preset wears."
  @spec server_names(map() | nil) :: [String.t()]
  def server_names(environment) when is_map(environment) do
    environment
    |> Map.get(:preset, Map.get(environment, "preset"))
    |> case do
      %{} = preset -> Map.get(preset, :identities, Map.get(preset, "identities", []))
      _ -> []
    end
    |> List.wrap()
    |> Enum.map(&public_name/1)
    |> Enum.reject(&is_nil/1)
  end

  def server_names(_), do: []

  @doc """
  The tools-proxy upstream for `server_name` when the job wears that identity.

  Returns the admitted public view as an upstream map, or nil when the preset
  does not wear it — in which case the proxy treats the name as unknown.
  """
  @spec upstream(Job.t(), String.t()) :: map() | nil
  def upstream(%Job{admitted_environment: environment}, server_name)
      when is_binary(server_name) do
    environment
    |> Map.get("preset", %{})
    |> Map.get("identities", [])
    |> List.wrap()
    |> Enum.find(&(public_name(&1) == server_name))
    |> case do
      nil -> nil
      admitted -> %{"identity" => Identity.public(admitted)}
    end
  end

  def upstream(_, _), do: nil

  @doc "Answer one MCP JSON-RPC request as the given identity."
  def call(%{name: name} = admitted, %{"method" => method} = rpc) do
    id = Map.get(rpc, "id")

    case method do
      "initialize" ->
        result(id, %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "omashiki-identity/" <> name, "version" => "1"}
        })

      "ping" ->
        result(id, %{})

      "notifications/" <> _ ->
        result(id, %{})

      "tools/list" ->
        result(id, %{"tools" => @tools})

      "tools/call" ->
        with {:ok, identity} <- live_identity(admitted) do
          params = Map.get(rpc, "params") || %{}
          tool_call(id, identity, Map.get(params, "name"), Map.get(params, "arguments") || %{})
        end

      _ ->
        {:error, %{code: -32601, message: "method_not_found"}}
    end
  end

  def call(_, _), do: {:error, %{code: -32600, message: "invalid_request"}}

  # The admitted view names the identity; the live house holds the key. If the
  # house no longer declares it, or declares it as a different App, the job
  # does not get to act as whatever the name now means.
  defp live_identity(admitted) do
    case Config.get_identity(admitted.name) do
      %Identity{} = identity ->
        if Identity.public(identity) == admitted,
          do: {:ok, identity},
          else: {:error, %{code: -32030, message: "identity_changed"}}

      nil ->
        {:error, %{code: -32030, message: "identity_unavailable"}}
    end
  end

  defp tool_call(id, identity, "github_get_issue", args) do
    with {:ok, repo, number} <- issue_ref(args) do
      github(id, identity, :get, "/repos/#{repo}/issues/#{number}", nil)
    end
  end

  defp tool_call(id, identity, "github_comment", args) do
    with {:ok, repo, number} <- issue_ref(args),
         {:ok, body} <- string(args, "body") do
      github(id, identity, :post, "/repos/#{repo}/issues/#{number}/comments", %{"body" => body})
    end
  end

  defp tool_call(id, identity, "github_add_labels", args) do
    with {:ok, repo, number} <- issue_ref(args),
         {:ok, labels} <- string_list(args, "labels") do
      github(id, identity, :post, "/repos/#{repo}/issues/#{number}/labels", %{
        "labels" => labels
      })
    end
  end

  defp tool_call(id, identity, "github_create_pull_request", args) do
    with {:ok, repo} <- repository(args),
         {:ok, title} <- string(args, "title"),
         {:ok, head} <- string(args, "head"),
         {:ok, base} <- string(args, "base") do
      body =
        %{"title" => title, "head" => head, "base" => base}
        |> maybe_put("body", Map.get(args, "body"))
        |> maybe_put("draft", Map.get(args, "draft"))

      github(id, identity, :post, "/repos/#{repo}/pulls", body)
    end
  end

  defp tool_call(_id, _identity, tool, _args),
    do: {:error, %{code: -32601, message: "unknown_tool", data: %{tool: tool}}}

  defp github(id, identity, method, path, body) do
    case GithubApp.request(identity, method, path, body) do
      {:ok, status, decoded} when status in 200..299 ->
        result(id, %{"content" => [text(decoded)], "isError" => false})

      {:ok, status, decoded} ->
        Logger.warning(
          "[Identities.Broker] #{identity.name} github #{method} #{path} -> #{status}"
        )

        result(id, %{
          "content" => [text(%{"status" => status, "response" => decoded})],
          "isError" => true
        })

      {:error, reason} ->
        Logger.warning(
          "[Identities.Broker] #{identity.name} github unavailable: #{inspect(reason)}"
        )

        {:error, %{code: -32020, message: "github_unavailable"}}
    end
  end

  defp text(value) when is_binary(value), do: %{"type" => "text", "text" => value}
  defp text(value), do: %{"type" => "text", "text" => Jason.encode!(value)}

  defp result(id, result), do: {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}

  defp issue_ref(args) do
    with {:ok, repo} <- repository(args) do
      case Map.get(args, "number") do
        n when is_integer(n) and n > 0 -> {:ok, repo, n}
        _ -> invalid("number must be a positive integer")
      end
    end
  end

  # `owner/name`, one slash, no segment that is only dots: the value is spliced
  # into a URL path and must never be able to climb out of `/repos/`.
  defp repository(args) do
    case Map.get(args, "repository") do
      repo when is_binary(repo) ->
        segments = String.split(repo, "/")

        if Regex.match?(@repository, repo) and
             Enum.all?(segments, &(not Regex.match?(~r/^\.+$/, &1))),
           do: {:ok, repo},
           else: invalid("repository must be owner/name")

      _ ->
        invalid("repository is required")
    end
  end

  defp string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid("#{key} must be a non-empty string")
    end
  end

  defp string_list(args, key) do
    case Map.get(args, key) do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: {:ok, values},
          else: invalid("#{key} must be an array of strings")

      _ ->
        invalid("#{key} must be a non-empty array")
    end
  end

  defp invalid(message),
    do: {:error, %{code: -32602, message: "invalid_params", data: %{detail: message}}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp public_name(%{name: name}) when is_binary(name), do: name
  defp public_name(%{"name" => name}) when is_binary(name), do: name
  defp public_name(_), do: nil
end
