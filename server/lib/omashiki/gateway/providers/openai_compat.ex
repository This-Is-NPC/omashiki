defmodule Omashiki.Gateway.Providers.OpenaiCompat do
  @moduledoc """
  First outbound adapter: OpenAI-compatible `/v1/chat/completions`.

  Used for OpenAI, custom `base_url` credentials, and as the **interim**
  path for Anthropic until a native Messages adapter ships.

  ## Field loss (Anthropic via this adapter)

  Anthropic's OpenAI-compat surface (`https://api.anthropic.com/v1`) does
  **not** expose prompt-caching usage fields
  (`cache_creation_input_tokens` / `cache_read_input_tokens`), nor reliable
  reasoning-token breakdown. This adapter therefore returns
  `cached_input_tokens: nil`, `cache_write_tokens: nil`, and
  `reasoning_tokens: nil` whenever those keys are absent — never `0`, which
  would invent "zero" and collapse into fiction (Fase 0 / ledger honesty).

  Also lost vs Anthropic Messages: detailed cache controls, citations,
  extended thinking payloads, strict structured outputs, `n > 1`, logprobs.

  OpenAI may report `usage.prompt_tokens_details.cached_tokens`; when present
  it is recorded as `cached_input_tokens`.
  """

  @behaviour Omashiki.Gateway.Provider

  require Logger

  alias Omashiki.Credentials.Credential

  @anthropic_oai_base "https://api.anthropic.com/v1"
  @openai_base "https://api.openai.com/v1"
  @default_request_timeout_ms 120_000
  @recv_chunk_timeout_ms 30_000

  @impl true
  def chat_completions(%Credential{} = cred, body, model) do
    upstream = upstream_base(cred)
    url = upstream <> "/chat/completions"
    started_at = System.monotonic_time(:millisecond)
    messages = body["messages"] || body[:messages] || []
    tools = body["tools"] || body[:tools] || []

    Logger.info(
      "[Gateway.OpenaiCompat] Calling provider=#{cred.provider} model=#{model} url=#{url} messages=#{length(messages)} tools=#{length(tools)}"
    )

    # Gateway currently buffers a single JSON response for metering. AI SDK /
    # OpenCode default to `stream: true` (SSE); that body is not JSON and was
    # surfacing as `upstream_invalid_json`. Force non-stream until a streaming
    # adapter exists.
    outbound =
      body
      |> Map.put("model", model)
      |> Map.put("stream", false)
      |> Map.delete(:model)
      |> Map.delete(:stream)

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{cred.api_key}"}
    ]

    headers =
      if cred.provider == "anthropic" do
        [{"anthropic-version", "2023-06-01"} | headers]
      else
        headers
      end

    result =
      case post_json(url, headers, Jason.encode!(outbound)) do
        {:ok, status, resp_body} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, decoded} ->
              log_response_shape(decoded, cred.provider, model)
              {:ok, %{response: decoded, usage: extract_usage(decoded)}}

            {:error, _} ->
              {:error, %{status: 502, error: %{message: "upstream_invalid_json"}}}
          end

        {:ok, status, resp_body} ->
          {:error,
           %{status: status, error: %{message: String.slice(to_string(resp_body), 0, 300)}}}

        {:error, reason} ->
          {:error, reason}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, _} ->
        Logger.info(
          "[Gateway.OpenaiCompat] Completed provider=#{cred.provider} model=#{model} elapsed=#{elapsed_ms}ms"
        )

      {:error, reason} ->
        Logger.warning(
          "[Gateway.OpenaiCompat] Failed provider=#{cred.provider} model=#{model} elapsed=#{elapsed_ms}ms reason=#{inspect(reason)}"
        )
    end

    result
  end

  defp log_response_shape(decoded, provider, model) do
    choice = decoded |> Map.get("choices", []) |> List.first() || %{}
    tool_calls = get_in(choice, ["message", "tool_calls"]) || []

    Logger.info(
      "[Gateway.OpenaiCompat] Response provider=#{provider} model=#{model} finish_reason=#{inspect(choice["finish_reason"])} tool_calls=#{length(tool_calls)}"
    )
  end

  @doc false
  def upstream_base(%Credential{base_url: url}) when is_binary(url) and url != "" do
    url |> String.trim_trailing("/") |> String.trim_trailing("/v1") |> Kernel.<>("/v1")
  end

  def upstream_base(%Credential{provider: "anthropic"}), do: @anthropic_oai_base
  def upstream_base(%Credential{provider: "openai"}), do: @openai_base

  def upstream_base(%Credential{provider: provider}) do
    Logger.warning(
      "[Gateway.OpenaiCompat] no default upstream for provider=#{provider}; set credentials.base_url"
    )

    @openai_base
  end

  @doc """
  Map an OpenAI-shaped `usage` object into ledger fields.

  Cache columns are **nil when absent** — absence is not zero.
  """
  def extract_usage(response) when is_map(response) do
    usage = response["usage"] || response[:usage] || %{}
    request_id = response["id"] || response[:id]

    %{
      input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
      cached_input_tokens: cached_tokens(usage),
      cache_write_tokens: cache_write_tokens(usage),
      reasoning_tokens:
        usage["reasoning_tokens"] ||
          get_in(usage, ["completion_tokens_details", "reasoning_tokens"]),
      provider_request_id: request_id && to_string(request_id)
    }
  end

  # OpenAI: prompt_tokens_details.cached_tokens
  # Anthropic Messages (native, future): cache_read_input_tokens
  # Anthropic OAI-compat: neither — stays nil (documented above).
  defp cached_tokens(usage) do
    get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
      usage["cache_read_input_tokens"] ||
      nil
  end

  defp cache_write_tokens(usage) do
    usage["cache_creation_input_tokens"] || usage["cache_write_tokens"] || nil
  end

  # ---------------------------------------------------------------------------
  # Mint HTTP
  # ---------------------------------------------------------------------------

  defp post_json(url, headers, body) do
    uri = URI.parse(url)

    scheme =
      case uri.scheme do
        "https" -> :https
        _ -> :http
      end

    host = uri.host || "localhost"
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = encode_path(uri)

    mint_headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, host, port,
             mode: :passive,
             transport_opts: [timeout: 30_000]
           ),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", path, mint_headers, body) do
      deadline = System.monotonic_time(:millisecond) + provider_request_timeout_ms()
      receive_http(conn, ref, "", nil, deadline)
    end
  rescue
    e -> {:error, e}
  end

  defp encode_path(%URI{path: path, query: query}) do
    base = path || "/"
    if query, do: base <> "?" <> query, else: base
  end

  defp provider_request_timeout_ms do
    Application.get_env(:omashiki, :gateway_provider_request_timeout_ms, @default_request_timeout_ms)
  end

  defp receive_http(conn, ref, body, status, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mint.HTTP.close(conn)
      {:error, :timeout}
    else
      recv_timeout = min(remaining, @recv_chunk_timeout_ms)

      case Mint.HTTP.recv(conn, 0, recv_timeout) do
        {:ok, conn, responses} ->
          {body, status, done?} =
            Enum.reduce(responses, {body, status, false}, fn
              {:status, ^ref, s}, {b, _, d} -> {b, s, d}
              {:headers, ^ref, _}, acc -> acc
              {:data, ^ref, chunk}, {b, s, d} -> {b <> chunk, s, d}
              {:done, ^ref}, {b, s, _} -> {b, s, true}
              _, acc -> acc
            end)

          if done? do
            Mint.HTTP.close(conn)
            {:ok, status || 0, body}
          else
            receive_http(conn, ref, body, status, deadline)
          end

        {:error, conn, reason, _} ->
          Mint.HTTP.close(conn)
          {:error, normalize_http_error(reason)}
      end
    end
  end

  defp normalize_http_error(:timeout), do: :timeout
  defp normalize_http_error(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp normalize_http_error(reason), do: reason
end
