defmodule OmashikiWeb.Api.GatewayController do
  @moduledoc """
  OpenAI-compatible HTTP surface for agent containers.

  `POST /api/v1/gateway/v1/chat/completions` — Bearer is a gateway token
  minted at provision time, not the provider API key.

  Upstream is always buffered (non-stream) for metering. When the client
  asks for `stream: true` (OpenCode / AI SDK default), the buffered
  completion is rewritten as a short SSE sequence so the client does not
  hang waiting for `data:` frames.
  """

  use OmashikiWeb, :controller

  alias Omashiki.Gateway

  def chat_completions(conn, _params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, claims} <- Gateway.verify_token(token),
         body when is_map(body) <- conn.body_params do
      case Gateway.chat_completions(body, claims) do
        {:ok, response} ->
          if stream_requested?(body) do
            send_sse_completion(conn, response)
          else
            json(conn, response)
          end

        {:error, %{status: status, error: error}} ->
          conn
          |> put_status(status)
          |> json(%{error: error})

        {:error, other} ->
          conn
          |> put_status(502)
          |> json(%{error: %{message: inspect(other), type: "upstream"}})
      end
    else
      {:error, :missing_token} ->
        conn |> put_status(:unauthorized) |> json(%{error: %{message: "missing_token"}})

      {:error, _} ->
        conn |> put_status(:unauthorized) |> json(%{error: %{message: "invalid_token"}})

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: %{message: "invalid_body"}})
    end
  end

  defp stream_requested?(body) do
    case body["stream"] || body[:stream] do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp send_sse_completion(conn, response) when is_map(response) do
    payload = sse_payload(response)

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, payload)
  end

  @doc false
  def sse_payload(response) when is_map(response) do
    id = response["id"] || response[:id] || "chatcmpl-omashiki"
    model = response["model"] || response[:model] || "unknown"
    created = response["created"] || response[:created] || System.system_time(:second)
    choice = response |> choices() |> List.first() || %{}
    message = choice["message"] || choice[:message] || %{}

    delta =
      message
      |> Map.take(["role", "content", "tool_calls", "function_call", "refusal"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.put_new("role", "assistant")

    role_chunk = %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "delta" => delta,
          "finish_reason" => nil
        }
      ]
    }

    stop_chunk = %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => choice["finish_reason"] || choice[:finish_reason] || "stop"
        }
      ]
    }

    chunks = [role_chunk, stop_chunk] ++ usage_chunks(response, id, model, created)

    (Enum.map(chunks, &"data: #{Jason.encode!(&1)}\n\n") ++ ["data: [DONE]\n\n"])
    |> IO.iodata_to_binary()
  end

  defp choices(response), do: response["choices"] || response[:choices] || []

  defp usage_chunks(response, id, model, created) do
    case response["usage"] || response[:usage] do
      usage when is_map(usage) ->
        [
          %{
            "id" => id,
            "object" => "chat.completion.chunk",
            "created" => created,
            "model" => model,
            "choices" => [],
            "usage" => usage
          }
        ]

      _ ->
        []
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end
end
