defmodule Omashiki.Harness.OpenCode.Http do
  @moduledoc """
  Production HTTP/SSE client for `opencode serve`.

  Wraps the small subset of the OpenCode HTTP API the orchestrator drives:
  `POST /session`, `POST /session/:id/message`, `GET /event` (SSE),
  `DELETE /session/:id`.

  ## Ctx

  Expects a runtime capability injected by the orchestrator:

      %Omashiki.Runtime.Capability{transport: :http, endpoint: %{host: _, port: _}}

  Host/port stay inside the capability; dialing is this module's job.

  Token fields on `send_turn/3` use the neutral engine vocabulary
  (`input_tokens` / `output_tokens`); cache counters stay nil because
  opencode only reports prompt/completion.
  """

  require Logger

  @default_timeout_ms 10 * 60 * 1_000

  def start_session(ctx, opts \\ []) do
    endpoint = endpoint!(ctx)
    body = Map.new(opts) |> Jason.encode!()
    headers = [{"content-type", "application/json"}]
    Logger.info("[OpenCode] Creating session at #{endpoint.host}:#{endpoint.port}")

    result =
      case request(endpoint, "POST", "/session", headers, body) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          case Jason.decode(resp) do
            {:ok, %{"id" => id}} -> {:ok, id}
            {:ok, _} -> {:error, :unexpected_response}
            {:error, e} -> {:error, {:invalid_json, e}}
          end

        {:ok, %{status: status, body: resp}} ->
          {:error, {:http_error, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:ok, id} ->
        Logger.info("[OpenCode] Session created id=#{id}")

      {:error, reason} ->
        Logger.warning("[OpenCode] Session creation failed: #{inspect(reason)}")
    end

    result
  end

  def send_turn(ctx, session_id, payload) when is_map(payload) do
    endpoint = endpoint!(ctx)
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}]
    path = "/session/#{URI.encode_www_form(session_id)}/message"
    started_at = System.monotonic_time(:millisecond)
    Logger.info("[OpenCode] Sending turn session=#{session_id}")

    result =
      case request(endpoint, "POST", path, headers, body, @default_timeout_ms) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          case Jason.decode(resp) do
            {:ok, decoded} -> {:ok, normalize_turn_result(decoded)}
            {:error, e} -> {:error, {:invalid_json, e}}
          end

        {:ok, %{status: status, body: resp}} ->
          {:error, {:http_error, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, _} ->
        Logger.info("[OpenCode] Turn completed session=#{session_id} elapsed=#{elapsed_ms}ms")

      {:error, reason} ->
        Logger.warning(
          "[OpenCode] Turn failed session=#{session_id} elapsed=#{elapsed_ms}ms reason=#{inspect(reason)}"
        )
    end

    result
  end

  def subscribe(ctx, _session, receiver) when is_pid(receiver) do
    endpoint = endpoint!(ctx)
    ref = make_ref()

    # Plain `spawn` (no link). The streamer reports lifecycle to the receiver
    # via `:opencode_event_error` / `:opencode_event_closed`; we don't want
    # streamer crashes (e.g. a Bypass-faked endpoint with no /global/event
    # route) to take down the driver.
    spawn(fn -> _ = stream_events(endpoint, receiver, ref) end)
    {:ok, ref}
  end

  def finish(ctx, session_id) do
    endpoint = endpoint!(ctx)

    case request(endpoint, "DELETE", "/session/#{URI.encode_www_form(session_id)}", [], nil) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoint!(capability) do
    case Omashiki.Runtime.Capability.endpoint(capability) do
      {:ok, endpoint} -> endpoint
      {:error, reason} -> raise ArgumentError, "OpenCode requires an HTTP capability: #{reason}"
    end
  end

  # Decodes the message envelope into the neutral turn_result the driver
  # persists. OpenCode's actual response surface is large; the orchestrator
  # only needs assistant text + token counts + resolved model.
  defp normalize_turn_result(decoded) when is_map(decoded) do
    info = decoded["info"] || %{}
    parts = decoded["parts"] || []

    text =
      parts
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    tokens = info["tokens"] || %{}

    %{
      assistant_text: text,
      input_tokens: tokens["input"] || 0,
      output_tokens: tokens["output"] || 0,
      # OpenCode HTTP path does not surface cache fields — unknown, not zero.
      cached_input_tokens: nil,
      cache_write_tokens: nil,
      model_resolved: info["modelID"] || info["model"],
      provider: info["providerID"] || info["provider"]
    }
  end

  # ---------------------------------------------------------------------------
  # SSE
  # ---------------------------------------------------------------------------

  defp stream_events(endpoint, receiver, ref) do
    case Mint.HTTP.connect(:http, endpoint.host, endpoint.port, mode: :passive) do
      {:ok, conn} ->
        case Mint.HTTP.request(
               conn,
               "GET",
               "/global/event",
               [{"accept", "text/event-stream"}],
               nil
             ) do
          {:ok, conn, req_ref} ->
            sse_loop(conn, req_ref, receiver, ref, "")

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            send(receiver, {:opencode_event_error, ref, reason})
        end

      {:error, reason} ->
        send(receiver, {:opencode_event_error, ref, reason})
    end
  end

  defp sse_loop(conn, req_ref, receiver, ref, buffer) do
    case Mint.HTTP.recv(conn, 0, 30_000) do
      {:ok, conn, responses} ->
        {buffer, done?} = process_sse(responses, req_ref, receiver, ref, buffer)
        if done?, do: Mint.HTTP.close(conn), else: sse_loop(conn, req_ref, receiver, ref, buffer)

      {:error, _conn, reason, _resp} ->
        send(receiver, {:opencode_event_error, ref, reason})
    end
  end

  defp process_sse(responses, req_ref, receiver, ref, buffer) do
    Enum.reduce(responses, {buffer, false}, fn
      {:status, ^req_ref, _status}, acc ->
        acc

      {:headers, ^req_ref, _headers}, acc ->
        acc

      {:data, ^req_ref, data}, {buf, done?} ->
        {new_buf, events} = split_sse_events(buf <> data)

        Enum.each(events, fn event ->
          send(receiver, {:opencode_event, ref, event})
        end)

        {new_buf, done?}

      {:done, ^req_ref}, {buf, _} ->
        send(receiver, {:opencode_event_closed, ref})
        {buf, true}

      _, acc ->
        acc
    end)
  end

  # Split on the standard `\n\n` event delimiter; each event is the raw `data:`
  # line(s) joined.
  defp split_sse_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case Enum.split(parts, length(parts) - 1) do
      {events, [tail]} ->
        decoded =
          events
          |> Enum.map(&parse_event/1)
          |> Enum.reject(&is_nil/1)

        {tail, decoded}

      _ ->
        {buffer, []}
    end
  end

  defp parse_event(""), do: nil

  defp parse_event(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.reduce("", fn line, acc ->
      case String.split(line, ":", parts: 2) do
        ["data", rest] -> acc <> String.trim_leading(rest)
        _ -> acc
      end
    end)
    |> case do
      "" ->
        nil

      data ->
        case Jason.decode(data) do
          {:ok, decoded} -> decoded
          _ -> %{"raw" => data}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP plumbing (one-shot requests; SSE handled separately)
  # ---------------------------------------------------------------------------

  defp request(endpoint, method, path, headers, body, timeout_ms \\ 30_000) do
    case Mint.HTTP.connect(:http, endpoint.host, endpoint.port, mode: :passive) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, method, path, headers, body || "") do
          {:ok, conn, req_ref} ->
            result = recv_full(conn, req_ref, timeout_ms)
            Mint.HTTP.close(conn)
            result

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_full(conn, req_ref, timeout_ms, acc \\ %{status: nil, body: ""}) do
    case Mint.HTTP.recv(conn, 0, timeout_ms) do
      {:ok, conn, responses} ->
        case fold_responses(responses, req_ref, acc) do
          {:done, final} -> {:ok, final}
          {:cont, next_acc} -> recv_full(conn, req_ref, timeout_ms, next_acc)
          {:error, reason} -> {:error, reason}
        end

      {:error, _conn, reason, _resp} ->
        {:error, reason}
    end
  end

  defp fold_responses([], _req_ref, acc), do: {:cont, acc}

  defp fold_responses([head | rest], req_ref, acc) do
    case head do
      {:status, ^req_ref, status} ->
        fold_responses(rest, req_ref, %{acc | status: status})

      {:headers, ^req_ref, _headers} ->
        fold_responses(rest, req_ref, acc)

      {:data, ^req_ref, data} ->
        fold_responses(rest, req_ref, %{acc | body: acc.body <> data})

      {:done, ^req_ref} ->
        {:done, acc}

      {:error, ^req_ref, reason} ->
        {:error, reason}

      _ ->
        fold_responses(rest, req_ref, acc)
    end
  end
end
