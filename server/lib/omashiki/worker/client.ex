defmodule Omashiki.Worker.Client do
  @moduledoc false

  alias Omashiki.Worker.{Complete, Execution, Offer}

  @default_timeout_ms 30_000

  defstruct [:manager_url, :token, :mint_mod]

  @type t :: %__MODULE__{
          manager_url: String.t(),
          token: String.t(),
          mint_mod: module()
        }

  def new(url, token, opts \\ []) do
    %__MODULE__{
      manager_url: url |> to_string() |> String.trim_trailing("/"),
      token: token,
      mint_mod: Keyword.get(opts, :mint_mod, Mint.HTTP)
    }
  end

  def register(%__MODULE__{} = client, machine_id, free_slots)
      when is_binary(machine_id) and is_integer(free_slots) and free_slots >= 0 do
    body = Jason.encode!(%{"machine_id" => machine_id, "free_slots" => free_slots})

    with {:ok, %{status: status}} when status in 200..299 <-
           request(client, "POST", "/internal/work/register", json_headers(client), body) do
      :ok
    end
  end

  def poll(%__MODULE__{} = client, machine_id, free_slots)
      when is_binary(machine_id) and is_integer(free_slots) and free_slots >= 0 do
    body = Jason.encode!(%{"machine_id" => machine_id, "free_slots" => free_slots})

    with {:ok, %{status: status, body: resp}} when status in 200..299 <-
           request(client, "POST", "/internal/work/poll", json_headers(client), body),
         {:ok, decoded} <- Jason.decode(resp) do
      case Map.get(decoded, "offer") do
        nil ->
          {:ok, nil}

        offer_map ->
          case Offer.from_map(offer_map) do
            {:ok, offer} -> {:ok, offer}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  def heartbeat(%__MODULE__{} = client, %Execution{} = execution) do
    body =
      Jason.encode!(%{
        "attempt_id" => execution.attempt_id,
        "lease_token" => execution.lease_token
      })

    with {:ok, %{status: status, body: resp}} when status in 200..299 <-
           request(client, "POST", "/internal/work/heartbeat", json_headers(client), body),
         {:ok, %{"cancel" => cancel?}} <- Jason.decode(resp) do
      if cancel?, do: :cancel, else: :ok
    end
  end

  def put_blob(%__MODULE__{} = client, job_id, digest, binary)
      when is_binary(job_id) and is_binary(digest) and is_binary(binary) do
    headers =
      auth_headers(client) ++
        [
          {"content-type", "application/octet-stream"},
          {"x-omashiki-digest", digest}
        ]

    path = "/internal/work/blobs/#{URI.encode_www_form(job_id)}"

    with {:ok, %{status: status}} when status in 200..299 <-
           request(client, "PUT", path, headers, binary) do
      :ok
    end
  end

  def complete(%__MODULE__{} = client, %Execution{} = execution, %Complete{} = complete) do
    body =
      Jason.encode!(%{
        "attempt_id" => execution.attempt_id,
        "lease_token" => execution.lease_token,
        "complete" => Complete.to_map(complete)
      })

    with {:ok, %{status: status}} when status in 200..299 <-
           request(client, "POST", "/internal/work/complete", json_headers(client), body) do
      :ok
    end
  end

  defp json_headers(%__MODULE__{} = client) do
    auth_headers(client) ++ [{"content-type", "application/json"}]
  end

  defp auth_headers(%__MODULE__{token: token}) do
    [{"authorization", "Bearer #{token}"}]
  end

  defp request(%__MODULE__{} = client, method, path, headers, body, timeout_ms \\ @default_timeout_ms) do
    mint = client.mint_mod
    %URI{scheme: scheme, host: host, port: port} = URI.parse(client.manager_url)

    with {:ok, conn} <- mint.connect(scheme_atom(scheme), host, port_for(scheme, port), mode: :passive),
         {:ok, conn, req_ref} <- mint.request(conn, method, path, headers, body || ""),
         {:ok, response} <- recv_full(mint, conn, req_ref, timeout_ms) do
      mint.close(conn)
      map_http_response(response)
    else
      {:error, conn, reason} when is_pid(conn) ->
        mint.close(conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp map_http_response(%{status: status, body: _body}) when status in 401..403 do
    {:error, :unauthorized}
  end

  defp map_http_response(%{status: status, body: body}) when status in 400..499 do
    {:error, {:http, status, body}}
  end

  defp map_http_response(%{status: status} = response) when status in 200..299 do
    {:ok, response}
  end

  defp map_http_response(%{status: status, body: body}) do
    {:error, {:http, status, body}}
  end

  defp recv_full(mint, conn, req_ref, timeout_ms, acc \\ %{status: nil, body: ""}) do
    case mint.recv(conn, 0, timeout_ms) do
      {:ok, conn, responses} ->
        case fold_responses(responses, req_ref, acc) do
          {:done, final} -> {:ok, final}
          {:cont, next_acc} -> recv_full(mint, conn, req_ref, timeout_ms, next_acc)
          {:error, reason} -> {:error, reason}
        end

      {:error, _conn, reason, _responses} ->
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

  defp scheme_atom("https"), do: :https
  defp scheme_atom(_), do: :http

  defp port_for("https", nil), do: 443
  defp port_for("http", nil), do: 80
  defp port_for(_scheme, port), do: port
end
